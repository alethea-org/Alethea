defmodule Alethea.Clinical.SummaryEncryptionMigrationTest do
  @moduledoc """
  S1 (security-audit-run-2): `EncryptClinicalSummaries` moves existing
  plaintext summaries under the patient DEK.

  The test database is already migrated, so each test re-adds the legacy
  `summary_text` column inside the sandbox transaction (rolled back at the
  end), inserts pre-migration rows and runs the migration's backfill.
  `async: false` because that DDL locks `clinical_summaries`.
  """

  use Alethea.DataCase, async: false

  alias Alethea.{Accounts, Clinical, Repo}
  alias Alethea.Repo.Migrations.EncryptClinicalSummaries, as: Migration

  @migration_path Path.expand(
                    "../../../priv/repo/migrations/20261127132555_encrypt_clinical_summaries.exs",
                    __DIR__
                  )

  setup_all do
    Code.require_file(@migration_path)
    :ok
  end

  setup do
    Repo.query!("ALTER TABLE clinical_summaries ADD COLUMN summary_text text")

    {:ok, professional} =
      Accounts.create_professional(%{
        email: "summary-mig-#{System.unique_integer([:positive])}@example.com",
        password: "securepassword123",
        full_name: "Migration Tester"
      })

    %{professional: professional}
  end

  defp keyed_patient(professional) do
    {:ok, kek} = Accounts.load_professional_kek(professional)

    {:ok, patient} =
      Accounts.create_patient(%{"alias" => "Keyed", "professional_id" => professional.id}, kek)

    patient
  end

  defp insert_legacy!(patient, text, type) do
    id = Ecto.UUID.generate()
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Repo.query!(
      "INSERT INTO clinical_summaries " <>
        "(id, patient_id, period_start, period_end, summary_text, status_level, type, " <>
        "inserted_at, updated_at) VALUES ($1, $2, $3, $3, $4, 'Estable', $5, $3, $3)",
      [Ecto.UUID.dump!(id), Ecto.UUID.dump!(patient.id), now, text, type]
    )

    id
  end

  defp raw(id) do
    %{rows: [[plaintext, ciphertext]]} =
      Repo.query!(
        "SELECT summary_text, encrypted_summary FROM clinical_summaries WHERE id = $1",
        [Ecto.UUID.dump!(id)]
      )

    {plaintext, ciphertext}
  end

  test "an empty table is a no-op" do
    assert Migration.encrypt_existing!(Repo) == %{encrypted: 0, cleared: 0}
  end

  test "pre-existing plaintext rows are encrypted under the patient DEK and cleared", %{
    professional: professional
  } do
    patient = keyed_patient(professional)
    weekly = insert_legacy!(patient, "Semana legacy en texto plano", "weekly")
    session = insert_legacy!(patient, "Sesión legacy en texto plano", "session")

    assert Migration.encrypt_existing!(Repo) == %{encrypted: 2, cleared: 0}

    for id <- [weekly, session] do
      assert {nil, ciphertext} = raw(id)
      assert is_binary(ciphertext)
      refute ciphertext =~ "legacy"
    end

    assert %{summary_text: "Semana legacy en texto plano"} =
             Clinical.latest_weekly_summary(patient.id)

    since = DateTime.add(DateTime.utc_now(), -1, :day)

    assert [%{summary_text: "Sesión legacy en texto plano"}] =
             Clinical.list_session_summaries(patient.id, since)

    # Idempotent: a second run finds no plaintext left.
    assert Migration.encrypt_existing!(Repo) == %{encrypted: 0, cleared: 0}
  end

  test "rows of a patient without a key lose their plaintext and stay unreadable", %{
    professional: professional
  } do
    {:ok, keyless} =
      Accounts.create_patient(%{alias: "Sin llave", professional_id: professional.id})

    id = insert_legacy!(keyless, "Texto de paciente sin llave", "weekly")

    assert Migration.encrypt_existing!(Repo) == %{encrypted: 0, cleared: 1}
    assert {nil, nil} = raw(id)
    assert %{summary_text: nil} = Clinical.latest_weekly_summary(keyless.id)
  end
end
