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

  alias Alethea.Accounts.Patient
  alias Alethea.Clinical
  alias Alethea.Clinical.RunningSummary.Snapshot
  alias Alethea.Encryption.PatientVault
  alias Alethea.Repo

  @loading_reason "running_summary_loading"

  @type plan :: %{
          mode: :first | :incremental,
          expected: non_neg_integer(),
          target_count: pos_integer(),
          target: %{id: Ecto.UUID.t()}
        }

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
