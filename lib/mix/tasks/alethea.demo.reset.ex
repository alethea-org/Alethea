defmodule Mix.Tasks.Alethea.Demo.Reset do
  use Mix.Task

  alias Alethea.Operator.TaskRuntime
  alias Alethea.Repo

  @shortdoc "Deletes local development demo data while preserving Telegram BotConfig"

  @moduledoc """
  Deletes all local development identities, clinical records, Telegram bindings,
  authentication codes, dead letters, and Oban jobs in one transaction.

  The encrypted rows in `foundation_bot_configs`, schema migrations, and Oban peer
  coordination state are preserved. The task is restricted to `MIX_ENV=dev` and
  requires an explicit confirmation flag:

      mix alethea.demo.reset --confirm

  Output contains aggregate deletion counts only. It never prints identities,
  clinical content, credentials, tokens, or ciphertext.
  """

  @switches [confirm: :boolean]

  @lock_tables ~w(
    ai_diagnoses
    audit_logs
    clinical_sessions
    clinical_summaries
    clinical_trends
    emotion_analyses
    encryption_keys
    foundation_admins
    foundation_outbound_dead_letters
    foundation_patient_auth_codes
    foundation_patients
    foundation_professionals
    messages
    oban_jobs
    patients
    professionals
  )

  @delete_groups [
    jobs: ~w(oban_jobs),
    delivery: ~w(foundation_outbound_dead_letters foundation_patient_auth_codes),
    clinical:
      ~w(ai_diagnoses emotion_analyses messages clinical_summaries clinical_trends clinical_sessions),
    foundation_accounts: ~w(foundation_patients foundation_professionals foundation_admins),
    legacy_accounts: ~w(audit_logs patients encryption_keys professionals)
  ]

  @impl Mix.Task
  def run(args), do: run(args, Mix.env())

  @doc false
  def run(args, env) do
    validate_env!(env)
    validate_args!(args)
    Mix.Task.run("app.config")

    {counts, bot_config_count} = execute_reset!()

    Mix.shell().info(
      "ALETHEA_DEMO_RESET_COMPLETE " <>
        "jobs=#{counts.jobs} " <>
        "delivery=#{counts.delivery} " <>
        "clinical=#{counts.clinical} " <>
        "foundation_accounts=#{counts.foundation_accounts} " <>
        "legacy_accounts=#{counts.legacy_accounts} " <>
        "bot_configs_preserved=#{bot_config_count}"
    )
  end

  defp validate_env!(:dev), do: :ok

  defp validate_env!(_env) do
    Mix.raise("ALETHEA_DEMO_RESET_FAILED reason=development_only")
  end

  defp validate_args!(args) do
    case OptionParser.parse(args, strict: @switches) do
      {[confirm: true], [], []} -> :ok
      _ -> Mix.raise("usage: mix alethea.demo.reset --confirm")
    end
  end

  defp execute_reset! do
    result =
      try do
        TaskRuntime.with_services(fn -> Repo.transaction(&reset/0, log: false) end)
      rescue
        _error -> :transaction_failed
      catch
        :exit, _reason -> :transaction_failed
      end

    case result do
      {:ok, reset_result} -> reset_result
      _failure -> Mix.raise("ALETHEA_DEMO_RESET_FAILED reason=transaction_failed")
    end
  end

  defp reset do
    lock_tables!()
    bot_config_count = table_count("foundation_bot_configs")

    counts =
      Map.new(@delete_groups, fn {category, tables} ->
        {category, Enum.reduce(tables, 0, &(&2 + delete_all!(&1)))}
      end)

    if table_count("foundation_bot_configs") != bot_config_count do
      Repo.rollback(:bot_config_changed)
    end

    {counts, bot_config_count}
  end

  defp lock_tables! do
    Repo.query!(
      "LOCK TABLE #{Enum.join(@lock_tables, ", ")} IN ACCESS EXCLUSIVE MODE",
      [],
      log: false
    )

    Repo.query!("LOCK TABLE foundation_bot_configs IN SHARE MODE", [], log: false)
  end

  defp delete_all!(table) do
    Repo.query!("DELETE FROM #{table}", [], log: false).num_rows
  end

  defp table_count(table) do
    Repo.query!("SELECT count(*) FROM #{table}", [], log: false).rows |> hd() |> hd()
  end
end
