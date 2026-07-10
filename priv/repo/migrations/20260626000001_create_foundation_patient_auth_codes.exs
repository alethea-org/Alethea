defmodule Alethea.Repo.Migrations.CreateFoundationPatientAuthCodes do
  @moduledoc """
  Creates the `foundation_patient_auth_codes` table (C-4, PR #4).

  Persists the ephemeral deep-link token (`kind: "deep_link"`, minted
  by `Alethea.Telegram.DeepLinkToken.mint/0`) and the six-digit web
  fallback code (`kind: "six_digit"`) that bind a Telegram chat to a
  `foundation_patients` row. Both kinds share the same TTL (10 min),
  single-use (`used_at`), and rate-limit (`attempt_count` +
  `last_attempt_ip`) semantics — see
  `Alethea.Foundation.Accounts.PatientAuthCode` for the full contract.

  ## Why one table for both kinds

  The two kinds share every column and every state-machine transition
  (mint → verify → consume). A `kind` discriminator column is simpler
  than two near-identical tables, and the `(patient_id, code, kind)`
  unique index lets a patient hold one active code per kind without
  a cross-kind collision.

  ## No FK cascade footgun

  `on_delete: :delete_all` — deleting a `foundation_patients` row
  deletes its auth codes too. Unlike the dead-letter table (audit,
  intentionally decoupled), an auth code has no meaning once its
  patient is gone; there is no operator value in keeping a dangling
  onboarding code around.
  """

  use Ecto.Migration

  def change do
    create table(:foundation_patient_auth_codes, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :patient_id, references(:foundation_patients, type: :binary_id, on_delete: :delete_all),
        null: false

      # 43-char URL-safe base64 (deep_link) or 6-digit numeric string
      # (six_digit). Not globally unique by itself — see the
      # `(patient_id, code, kind)` index below.
      add :code, :string, null: false

      # "deep_link" | "six_digit"
      add :kind, :string, null: false

      add :expires_at, :utc_datetime, null: false
      add :used_at, :utc_datetime

      # Rate-limit audit trail (REQ-C4-reject-rate-limited). Updated on
      # every `verify_patient_auth_code/3` call — see the schema
      # moduledoc for the per-IP rolling-window algorithm.
      add :attempt_count, :integer, default: 0, null: false
      add :last_attempt_ip, :string

      timestamps(type: :utc_datetime)
    end

    # A patient cannot have two active codes with the identical
    # (code, kind) pair. In practice `code` is unique per mint (deep-link
    # entropy is 256 bits; six-digit codes can theoretically repeat
    # across different patients within the 10-min TTL window — see
    # `PatientAuthCode` moduledoc for the accepted collision-probability
    # rationale).
    create unique_index(:foundation_patient_auth_codes, [:patient_id, :code, :kind],
             name: :foundation_patient_auth_codes_patient_code_kind_unique
           )

    # Lookup by code + kind for verify (covers the deep-link redirect
    # and six-digit web fallback paths).
    create index(:foundation_patient_auth_codes, [:code, :kind])

    # Cleanup job prunes WHERE expires_at < now() AND used_at IS NULL.
    create index(:foundation_patient_auth_codes, [:expires_at])

    # Rate-limit lookup / audit: WHERE last_attempt_ip = $1 AND
    # inserted_at > now() - 1h.
    create index(:foundation_patient_auth_codes, [:last_attempt_ip, :inserted_at])
  end
end
