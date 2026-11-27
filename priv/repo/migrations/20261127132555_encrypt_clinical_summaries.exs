defmodule Alethea.Repo.Migrations.EncryptClinicalSummaries do
  @moduledoc """
  Moves `clinical_summaries.summary_text` under the patient DEK
  (security-audit-run-2, S1).

  `up/0`:

    1. Adds `encrypted_summary` (binary): AES-256-GCM ciphertext under the
       patient's DEK, the same `Alethea.Encryption.PatientVault` scheme
       `messages.encrypted_content` and `running_summaries.encrypted_summary`
       use.
    2. Encrypts every existing plaintext row and sets its `summary_text` to
       NULL in the same UPDATE, so the live tuples stop carrying the
       plaintext (a dropped column's bytes otherwise stay in live rows).
       Before anything is written, every patient's key is resolved. If a
       row whose patient has no recoverable key (no key, key row gone,
       professional KEK gone) still holds non-empty plaintext, the
       migration raises with the row and patient counts (never the text)
       and rolls back, so no clinical narrative is lost: an operator must
       resolve those patients first. Only an empty `summary_text` of such a
       patient is cleared. Any other key failure (for example a wrong
       `CLOAK_AES_KEY`) also raises and rolls back. A successful run logs
       the encrypted and cleared counts.
    3. Drops `summary_text`.

  An empty table never touches the vault or application code.

  `down/0` is irreversible on purpose: restoring a plaintext column would
  re-create exactly the exposure this migration removes, and rows of
  erased patients have no plaintext left to restore.

  Old row versions and existing backups still hold the plaintext until
  Postgres vacuums the table and the backups age out.
  """

  use Ecto.Migration

  require Logger

  alias Alethea.Encryption.PatientVault

  @audit_reason "summary_encryption_migration"

  def up do
    alter table(:clinical_summaries) do
      add :encrypted_summary, :binary
      modify :summary_text, :text, null: true, from: {:text, null: false}
    end

    flush()

    encrypt_existing!(repo())

    alter table(:clinical_summaries) do
      remove :summary_text, :text
    end
  end

  def down do
    raise Ecto.MigrationError,
      message:
        "EncryptClinicalSummaries is irreversible: summary plaintext is not restored " <>
          "outside the patient DEK"
  end

  @doc false
  # Encrypts every row that still has plaintext. Returns
  # `%{encrypted: n, cleared: m}` (counts only, never content). Raises,
  # before writing anything, when a patient without a recoverable key
  # still has non-empty plaintext.
  def encrypt_existing!(repo) do
    %{rows: rows} =
      repo.query!(
        "SELECT id, patient_id, summary_text FROM clinical_summaries " <>
          "WHERE summary_text IS NOT NULL"
      )

    if rows == [] do
      %{encrypted: 0, cleared: 0}
    else
      with_vault(fn ->
        groups =
          rows
          |> Enum.group_by(fn [_id, patient_id, _text] -> patient_id end)
          |> Enum.map(fn {patient_id, patient_rows} ->
            {patient_dek!(repo, patient_id), patient_rows}
          end)

        refuse_stranded_plaintext!(groups)

        counts =
          Enum.reduce(groups, %{encrypted: 0, cleared: 0}, fn {dek, patient_rows}, acc ->
            encrypt_patient_rows!(repo, dek, patient_rows, acc)
          end)

        Logger.info(
          "EncryptClinicalSummaries: encrypted=#{counts.encrypted} cleared=#{counts.cleared}"
        )

        counts
      end)
    end
  end

  # A keyless patient's plaintext cannot be encrypted, and clearing it would
  # lose clinical narrative that was never erased on purpose: abort instead.
  defp refuse_stranded_plaintext!(groups) do
    stranded =
      for {:unrecoverable, patient_rows} <- groups,
          rows = Enum.reject(patient_rows, fn [_id, _patient_id, text] -> text == "" end),
          rows != [],
          do: length(rows)

    if stranded != [] do
      raise "EncryptClinicalSummaries aborted: #{Enum.sum(stranded)} summary row(s) of " <>
              "#{length(stranded)} patient(s) without a recoverable key still hold plaintext. " <>
              "Nothing was changed. Restore those patients' keys or export and remove the " <>
              "rows, then rerun the migration."
    end

    :ok
  end

  defp encrypt_patient_rows!(repo, dek, rows, acc) do
    Enum.reduce(rows, acc, fn [id, _patient_id, text], acc ->
      case encrypt(text, dek) do
        {:ok, ciphertext} ->
          repo.query!(
            "UPDATE clinical_summaries SET encrypted_summary = $1, summary_text = NULL " <>
              "WHERE id = $2",
            [ciphertext, id]
          )

          %{acc | encrypted: acc.encrypted + 1}

        :unrecoverable ->
          repo.query!(
            "UPDATE clinical_summaries SET encrypted_summary = NULL, summary_text = NULL " <>
              "WHERE id = $1",
            [id]
          )

          %{acc | cleared: acc.cleared + 1}
      end
    end)
  end

  defp encrypt(_text, :unrecoverable), do: :unrecoverable
  defp encrypt("", _dek), do: :unrecoverable

  defp encrypt(text, dek) do
    {:ok, _ciphertext} = PatientVault.encrypt(text, dek)
  end

  # Unwraps the DEK through `Alethea.Clinical.patient_dek/2` (the same
  # path every reader uses, audited). A missing key is the crypto-erased
  # state; anything else is unexpected and aborts the migration.
  defp patient_dek!(repo, patient_id) do
    case repo.get(Alethea.Accounts.Patient, Ecto.UUID.load!(patient_id)) do
      %{encryption_key_id: key_id} = patient when not is_nil(key_id) ->
        case Alethea.Clinical.patient_dek(patient, @audit_reason) do
          {:ok, dek} -> dek
          {:error, reason} when reason in [:missing_encryption_key, :not_found] -> :unrecoverable
          {:error, reason} -> raise "cannot unwrap a patient DEK: #{inspect(reason)}"
        end

      _no_key ->
        :unrecoverable
    end
  end

  # `Alethea.Release.migrate/0` starts only the repo; the professional KEK
  # is sealed with `Alethea.Encryption.Vault`, so start it when it is not
  # already running (tests and a running node already have it).
  defp with_vault(fun) do
    {:ok, _apps} = Application.ensure_all_started(:cloak_ecto)

    case Process.whereis(Alethea.Encryption.Vault) do
      nil ->
        {:ok, pid} = Alethea.Encryption.Vault.start_link()

        try do
          fun.()
        after
          GenServer.stop(pid)
        end

      _pid ->
        fun.()
    end
  end
end
