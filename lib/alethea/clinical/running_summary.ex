defmodule Alethea.Clinical.RunningSummary do
  @moduledoc """
  Storage and read/write API for the protected factual running summary (#394).

  Every query is scoped by both `patient_id` and `professional_id`, and the
  composite FK `(patient_id, professional_id) -> patients` rejects a
  mismatched tenant at the database. Writes are compare-and-swap on
  `covered_inbound_count`, so concurrent jobs can never regress or overwrite
  each other. The module never logs or returns plaintext outside `{:ok, text}`.
  """

  import Ecto.Query

  require Logger

  alias Alethea.Accounts.Patient
  alias Alethea.AI.LLMConfig
  alias Alethea.Clinical
  alias Alethea.Clinical.Message
  alias Alethea.Clinical.RunningSummary.Snapshot
  alias Alethea.Encryption.PatientVault
  alias Alethea.Repo
  alias Alethea.Telegram.LogRedactor
  alias AletheaJobs.RunningSummaryWorker

  @loading_reason "running_summary_loading"
  @batch 10
  @window_cap 40

  @type plan :: %{
          required(:mode) => :first | :incremental,
          required(:expected) => non_neg_integer(),
          required(:target_count) => pos_integer(),
          required(:target) => %{id: Ecto.UUID.t()},
          optional(:lower_bound) => DateTime.t() | nil,
          optional(:anchor_ciphertext) => binary() | nil
        }

  @doc """
  True iff the running summary can run: its chain is pinned to the local
  provider, so it needs a non-blank local LLM endpoint
  (`LOCAL_LLM_BASE_URL`). Production has no localhost default.
  """
  @spec enabled?() :: boolean()
  def enabled? do
    case LLMConfig.get(:running_summary).endpoint_url do
      url when is_binary(url) -> String.trim(url) != ""
      _ -> false
    end
  end

  @doc """
  Logs once, at boot, that the summary is disabled for lack of a local LLM
  endpoint. Logs nothing while it is enabled; carries no patient data.
  """
  @spec log_boot_status() :: :ok
  def log_boot_status do
    if not enabled?() do
      Logger.warning(
        "RunningSummary: running summary disabled, no local LLM endpoint is configured " <>
          "(set LOCAL_LLM_BASE_URL); no summary jobs will be enqueued"
      )
    end

    :ok
  end

  @doc """
  Enqueues a `RunningSummaryWorker` job when the patient's persisted inbound
  count is at least #{@batch} ahead of the stored row (or the row must be
  reset), and only while `enabled?/0`. Never raises: any failure is logged as
  an atom and swallowed so the inbound pipeline is unaffected.
  """
  @spec schedule_if_due(Ecto.UUID.t(), String.t()) :: :ok
  def schedule_if_due(patient_id, hash_prefix) do
    with true <- enabled?(),
         %Patient{} = patient <- Repo.get(Patient, patient_id),
         {decision, _count, _row} when decision != :not_due <- assess(patient),
         {:error, _} <- Oban.insert(RunningSummaryWorker.new(%{"patient_id" => patient.id})) do
      warn(:enqueue_failed, hash_prefix)
    end

    :ok
  rescue
    error -> warn(error.__struct__, hash_prefix)
  catch
    kind, _ -> warn(kind, hash_prefix)
  end

  @doc "Decides the next step from persisted counts only; nothing is decrypted."
  @spec plan(Patient.t()) :: :not_due | {:reset, pos_integer()} | {:build, plan()}
  def plan(%Patient{} = patient) do
    {decision, count, row} = assess(patient)
    build_plan(decision, patient, count, row)
  end

  @doc """
  Decrypted window for `plan`: same population and `(timestamp, direction, id)`
  order as `Clinical.list_conversation_turns/3` (superseded replies excluded),
  up to and including the target inbound, newest #{@window_cap} turns, oldest
  first. Incremental plans start at the anchor's (closed) second.
  """
  @spec window_turns(Patient.t(), plan(), binary()) ::
          {:ok, [Clinical.conversation_turn()]} | {:error, :decrypt_failed}
  def window_turns(%Patient{id: patient_id}, %{target: target} = plan, dek) do
    patient_id
    |> window_messages(target, Map.get(plan, :lower_bound))
    |> Enum.reduce_while({:ok, []}, fn message, {:ok, turns} ->
      case Clinical.decrypt_message_content(message, dek) do
        {:ok, content} -> {:cont, {:ok, [%{role: role(message), content: content} | turns]}}
        _ -> {:halt, {:error, :decrypt_failed}}
      end
    end)
  end

  @doc "True when a row exists for exactly this patient and professional. No decrypt."
  @spec exists?(Patient.t()) :: boolean()
  def exists?(%Patient{} = patient), do: Repo.exists?(scoped(patient))

  @doc """
  Loads and decrypts the stored summary under the journaling DEK, audited as
  `running_summary_loading`. Returns `:none` (no DEK unwrap, no audit) when
  there is no row.
  """
  @spec load_usable(Patient.t()) :: {:ok, String.t()} | :none | {:error, atom()}
  def load_usable(%Patient{} = patient) do
    case Repo.one(scoped(patient)) do
      nil -> :none
      %Snapshot{} = row -> decrypt_row(patient, row)
    end
  end

  @doc """
  Persists `ciphertext` with CAS on `covered_inbound_count`.

  `:first` inserts only when the patient has no row; `:incremental` updates
  only while the stored count still equals `plan.expected`. A lost race
  returns `{:error, :stale}` and leaves the row untouched.
  """
  @spec write(plan(), binary(), Patient.t()) :: :ok | {:error, :stale | :persist_failed}
  def write(
        %{mode: mode, expected: expected, target_count: new, target: %{id: message_id}},
        ciphertext,
        %Patient{} = patient
      )
      when is_binary(ciphertext) and is_integer(expected) and is_integer(new) and new > expected do
    mode |> do_write(expected, new, message_id, ciphertext, patient) |> cas_result()
  rescue
    _ in [Postgrex.Error, Ecto.ConstraintError, DBConnection.ConnectionError] ->
      {:error, :persist_failed}
  end

  def write(_plan, _ciphertext, _patient), do: {:error, :persist_failed}

  @doc "Deletes the row only if its count still equals `observed` (CAS reset)."
  @spec reset(Patient.t(), pos_integer()) :: :ok | {:error, :stale}
  def reset(%Patient{} = patient, observed) when is_integer(observed) do
    {deleted, _} =
      patient
      |> scoped()
      |> where([s], s.covered_inbound_count == ^observed)
      |> Repo.delete_all()

    if deleted == 1, do: :ok, else: {:error, :stale}
  end

  @doc "Unconditionally removes the patient's row (used before any tenant reassignment)."
  @spec delete_for_patient(Patient.t()) :: :ok
  def delete_for_patient(%Patient{} = patient) do
    {_, _} = Repo.delete_all(scoped(patient))
    :ok
  end

  defp assess(patient) do
    count =
      Repo.aggregate(
        from(m in Message, where: m.patient_id == ^patient.id and m.direction == "inbound"),
        :count
      )

    row =
      patient
      |> scoped()
      |> select(
        [s],
        map(s, [:covered_inbound_count, :covered_through_message_id, :encrypted_summary])
      )
      |> Repo.one()

    {decide(count, row), count, row}
  end

  defp decide(count, nil) when count >= @batch, do: :first
  defp decide(_count, nil), do: :not_due
  defp decide(count, %{covered_inbound_count: covered}) when count < covered, do: :reset
  defp decide(_count, %{covered_through_message_id: nil}), do: :reset
  defp decide(count, %{covered_inbound_count: c}) when count - c >= @batch, do: :incremental
  defp decide(_count, _row), do: :not_due

  defp build_plan(:not_due, _patient, _count, _row), do: :not_due
  defp build_plan(:reset, _patient, _count, row), do: {:reset, row.covered_inbound_count}

  defp build_plan(:first, patient, count, _row) do
    target_plan(patient, %{mode: :first, expected: 0, target_count: div(count, @batch) * @batch})
  end

  defp build_plan(:incremental, patient, _count, row) do
    anchor = Repo.get_by(Message, id: row.covered_through_message_id, patient_id: patient.id)
    covered = row.covered_inbound_count

    if anchor do
      target_plan(patient, %{
        mode: :incremental,
        expected: covered,
        target_count: covered + @batch,
        lower_bound: anchor.timestamp,
        anchor_ciphertext: row.encrypted_summary
      })
    else
      {:reset, covered}
    end
  end

  defp target_plan(patient, plan) do
    target =
      Message
      |> where([m], m.patient_id == ^patient.id and m.direction == "inbound")
      |> order_by([m], asc: m.timestamp, asc: m.id)
      |> offset(^(plan.target_count - 1))
      |> limit(1)
      |> Repo.one()

    if target, do: {:build, Map.put(plan, :target, target)}, else: :not_due
  end

  # Mirrors `Clinical.turns_before/3` (patient scope, superseded replies
  # excluded, same tuple order) with the bound inclusive of the target.
  defp window_messages(patient_id, target, lower_bound) do
    Message
    |> where([m], m.patient_id == ^patient_id)
    |> where([m], is_nil(m.delivery_state) or m.delivery_state != "superseded")
    |> where(
      [m],
      m.timestamp < ^target.timestamp or
        (m.timestamp == ^target.timestamp and m.direction < ^target.direction) or
        (m.timestamp == ^target.timestamp and m.direction == ^target.direction and
           m.id <= ^target.id)
    )
    |> then(fn q -> if lower_bound, do: where(q, [m], m.timestamp >= ^lower_bound), else: q end)
    |> order_by([m], desc: m.timestamp, desc: m.direction, desc: m.id)
    |> limit(^@window_cap)
    |> Repo.all()
  end

  defp role(%Message{direction: "inbound"}), do: :patient
  defp role(%Message{direction: "outbound"}), do: :alethea

  # Atoms and the redacted chat prefix only: never message text or reasons.
  defp warn(reason, hash_prefix) do
    Logger.warning(
      "RunningSummary: schedule_if_due failed (reason=#{inspect(reason)}, " <>
        "chat=#{LogRedactor.prefix(hash_prefix)})"
    )

    :ok
  end

  defp do_write(:first, _expected, new, message_id, ciphertext, patient) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Repo.insert_all(
      Snapshot,
      [
        %{
          id: Ecto.UUID.generate(),
          patient_id: patient.id,
          professional_id: patient.professional_id,
          encrypted_summary: ciphertext,
          encryption_version: 1,
          covered_inbound_count: new,
          covered_through_message_id: message_id,
          inserted_at: now,
          updated_at: now
        }
      ],
      on_conflict: :nothing,
      conflict_target: [:patient_id]
    )
  end

  defp do_write(:incremental, expected, new, message_id, ciphertext, patient) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    patient
    |> scoped()
    |> where([s], s.covered_inbound_count == ^expected)
    |> Repo.update_all(
      set: [
        encrypted_summary: ciphertext,
        encryption_version: 1,
        covered_inbound_count: new,
        covered_through_message_id: message_id,
        updated_at: now
      ]
    )
  end

  defp cas_result({1, _}), do: :ok
  defp cas_result({0, _}), do: {:error, :stale}

  defp decrypt_row(patient, row) do
    with {:ok, dek} <- Clinical.patient_dek(patient, @loading_reason),
         {:ok, text} <- PatientVault.decrypt(row.encrypted_summary, dek) do
      {:ok, text}
    else
      {:error, reason} when is_atom(reason) -> {:error, reason}
      _ -> {:error, :decrypt_failed}
    end
  end

  defp scoped(%Patient{id: patient_id, professional_id: professional_id}) do
    from(s in Snapshot,
      where: s.patient_id == ^patient_id and s.professional_id == ^professional_id
    )
  end
end
