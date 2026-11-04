defmodule Alethea.Triggers.ReactiveMatch do
  @moduledoc """
  Selects at most one reactive trigger for a patient burst (#448).

  Called by `Alethea.Telegram.JournalingReply` on the `:safe` path only,
  once per burst, before the journaling reply is generated:

    1. The patient's eligible reactive triggers are loaded
       (`Alethea.Triggers.eligible_reactive_triggers/2`). Without any, the
       matcher is never called.
    2. The configured `Alethea.AI.TriggerMatcherBehaviour` adapter is
       called once with the sanitized burst text and, per trigger, only its
       id and sanitized condition — bounded by `:trigger_match_timeout_ms`.
    3. The returned probabilities are paired with their triggers and
       `select_match/2` picks the single match against `threshold/0`.

  Every failure — no legacy patient, an undecryptable DEK, a matcher error,
  crash or timeout — degrades to `:none`: the reply is generated without a
  trigger, never delayed or failed because of one.
  """

  require Logger

  alias Alethea.Accounts
  alias Alethea.AI
  alias Alethea.AI.Sanitizer
  alias Alethea.Triggers
  alias Alethea.Triggers.Trigger

  @default_threshold 0.7
  @default_timeout_ms 5_000

  @typedoc "A trigger paired with the probability the matcher gave it."
  @type scored :: {%Trigger{}, float()}

  @doc """
  Finds the reactive trigger to weave into the reply to `sanitized_text`,
  for `patient` (the legacy `Alethea.Accounts.Patient`, or `nil` when the
  foundation patient is not linked).

  Returns `{:ok, {trigger, probability}}` — the trigger carries
  `decrypted_approved_text` — or `:none`.
  """
  @spec find(Accounts.Patient.t() | nil, String.t()) :: {:ok, scored()} | :none
  def find(nil, _sanitized_text), do: :none

  def find(%Accounts.Patient{} = patient, sanitized_text) when is_binary(sanitized_text) do
    with {:ok, [_ | _] = triggers} <- Triggers.eligible_reactive_triggers(patient),
         {:ok, probabilities} <- call_matcher(sanitized_text, candidates(triggers)) do
      triggers
      |> score(probabilities)
      |> select_match(threshold())
    else
      {:ok, []} ->
        :none

      {:error, reason} ->
        Logger.warning(
          "ReactiveMatch: replying without a reactive trigger (reason=#{reason_tag(reason)})"
        )

        :none
    end
  end

  @doc """
  Selects the reactive trigger to fire for one burst.

  `scored` is a list of `{trigger, probability}` pairs, in the order the
  triggers were offered to the matcher (oldest trigger first). Every
  probability is a float in `0.0..1.0`; the list may be empty.

  Returns `{:ok, {trigger, probability}}` for the single highest
  probability that reaches `threshold`, or `:none` when the list is empty
  or no probability reaches it. At most one trigger fires per burst.

  ## Open decisions (pinned by the tests in
  `test/alethea/triggers/reactive_match_test.exs`)

    * **Threshold boundary** — a probability exactly equal to `threshold`
      counts as a match (`>=`, inclusive). A strict `>` would make the
      configured value itself never fire.
    * **Ties** — when several triggers share the highest probability, the
      first one in `scored` wins, so the outcome is deterministic and
      favours the longest-standing trigger.
  """
  @spec select_match([{%Trigger{}, number()}], number()) ::
          {:ok, {%Trigger{}, number()}} | :none
  def select_match(scored, threshold) when is_list(scored) and is_number(threshold) do
    scored
    |> Enum.filter(fn {_trigger, prob} -> prob >= threshold end)
    |> case do
      [] -> :none
      candidates -> {:ok, Enum.max_by(candidates, fn {_trigger, prob} -> prob end)}
    end
  end

  @doc """
  The global probability floor for a reactive trigger to fire
  (`config :alethea, :trigger_match_threshold`).
  """
  @spec threshold() :: float()
  def threshold,
    do: Application.get_env(:alethea, :trigger_match_threshold, @default_threshold)

  # Only ids and sanitized condition text leave the domain: the condition is
  # written by the professional and may name people or contacts.
  defp candidates(triggers) do
    Enum.map(triggers, &%{id: &1.id, condition: Sanitizer.sanitize(&1.decrypted_condition)})
  end

  # A probability the adapter reports for an unknown id, or outside 0..1,
  # is dropped rather than trusted.
  defp score(triggers, probabilities) when is_map(probabilities) do
    Enum.flat_map(triggers, fn trigger ->
      case Map.get(probabilities, trigger.id) do
        p when is_number(p) and p >= 0 and p <= 1 -> [{trigger, p / 1}]
        _missing_or_invalid -> []
      end
    end)
  end

  # One bounded call per burst. The adapter runs in a task whose body never
  # raises or exits, so a crash cannot take the reply job down with it; a
  # call slower than the bound is killed.
  defp call_matcher(text, candidates) do
    matcher = AI.trigger_matcher()

    task =
      Task.async(fn ->
        try do
          matcher.match(text, candidates)
        rescue
          exception -> {:error, {:matcher_crashed, exception.__struct__}}
        catch
          kind, _reason -> {:error, {:matcher_crashed, kind}}
        end
      end)

    case Task.yield(task, timeout_ms()) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:ok, probabilities}} when is_map(probabilities) -> {:ok, probabilities}
      {:ok, {:error, reason}} -> {:error, reason}
      {:ok, _unexpected} -> {:error, :invalid_matcher_result}
      {:exit, _reason} -> {:error, :matcher_exited}
      nil -> {:error, :timeout}
    end
  end

  # An adapter's error term is not trusted to be free of text; only its
  # leading atom reaches the log.
  defp reason_tag(reason) when is_atom(reason), do: reason
  defp reason_tag(reason) when is_tuple(reason) and is_atom(elem(reason, 0)), do: elem(reason, 0)
  defp reason_tag(_reason), do: :other

  defp timeout_ms,
    do: Application.get_env(:alethea, :trigger_match_timeout_ms, @default_timeout_ms)
end
