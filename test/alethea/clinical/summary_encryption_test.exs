defmodule Alethea.Clinical.SummaryEncryptionTest do
  @moduledoc """
  S1 (security-audit-run-2): `clinical_summaries` stores the AI summary
  narrative only as ciphertext under the patient DEK, and every reader
  decrypts it back into the virtual `summary_text` field.
  """

  use Alethea.DataCase, async: true

  alias Alethea.{Accounts, Clinical, Repo}
  alias Alethea.Accounts.EncryptionKey
  alias Alethea.Clinical.Summary

  @marker "MARKER-SUMMARY-#{System.unique_integer([:positive])}"

  setup do
    {:ok, professional} =
      Accounts.create_professional(%{
        email: "summary-enc-#{System.unique_integer([:positive])}@example.com",
        password: "securepassword123",
        full_name: "Summary Tester"
      })

    {:ok, kek} = Accounts.load_professional_kek(professional)

    {:ok, patient} =
      Accounts.create_patient(
        %{"alias" => "Summary Patient", "professional_id" => professional.id},
        kek
      )

    %{patient: patient, professional: professional}
  end

  defp save!(patient, type, text \\ @marker) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    {:ok, summary} =
      Clinical.save_summary(%{
        period_start: DateTime.add(now, -1, :day),
        period_end: now,
        summary_text: text,
        status_level: "Estable",
        type: type,
        patient_id: patient.id
      })

    summary
  end

  defp raw_row(id) do
    %{columns: columns, rows: [row]} =
      Repo.query!("SELECT * FROM clinical_summaries WHERE id = $1", [Ecto.UUID.dump!(id)])

    Enum.zip(columns, row) |> Map.new()
  end

  defp destroy_patient_key!(patient) do
    Repo.delete!(Repo.get!(EncryptionKey, patient.encryption_key_id))
  end

  test "save_summary/1 leaves no plaintext summary in the database row", %{patient: patient} do
    summary = save!(patient, "session")
    row = raw_row(summary.id)

    refute Map.has_key?(row, "summary_text")

    for {column, value} <- row, is_binary(value) do
      refute value =~ @marker, "plaintext summary found in column #{column}"
    end

    assert is_binary(row["encrypted_summary"])
  end

  test "readers decrypt the summary with the patient DEK", %{patient: patient} do
    since = DateTime.add(DateTime.utc_now(), -30, :day)
    session = save!(patient, "session")
    weekly = save!(patient, "weekly")

    assert %Summary{id: id, summary_text: @marker} = Clinical.latest_weekly_summary(patient.id)
    assert id == weekly.id

    session_id = session.id

    assert [%Summary{id: ^session_id, summary_text: @marker}] =
             Clinical.list_session_summaries(patient.id, since)

    assert {[%Summary{summary_text: @marker}], false} =
             Clinical.list_session_summaries_page(patient.id, since)
  end

  test "destroying the patient key makes summaries unreadable without crashing", %{
    patient: patient
  } do
    since = DateTime.add(DateTime.utc_now(), -30, :day)
    save!(patient, "session")
    save!(patient, "weekly")

    destroy_patient_key!(patient)

    assert %Summary{summary_text: nil} = Clinical.latest_weekly_summary(patient.id)
    assert [%Summary{summary_text: nil}] = Clinical.list_session_summaries(patient.id, since)

    assert {[%Summary{summary_text: nil}], false} =
             Clinical.list_session_summaries_page(patient.id, since)
  end

  test "a patient without a key cannot store a summary, and nothing is persisted" do
    {:ok, professional} =
      Accounts.create_professional(%{
        email: "keyless-#{System.unique_integer([:positive])}@example.com",
        password: "securepassword123",
        full_name: "Keyless"
      })

    {:ok, keyless} =
      Accounts.create_patient(%{alias: "Sin llave", professional_id: professional.id})

    assert {:error, %Ecto.Changeset{} = changeset} =
             Clinical.save_summary(%{
               period_start: DateTime.utc_now() |> DateTime.truncate(:second),
               period_end: DateTime.utc_now() |> DateTime.truncate(:second),
               summary_text: @marker,
               status_level: "Estable",
               type: "session",
               patient_id: keyless.id
             })

    assert Keyword.has_key?(changeset.errors, :summary_text)
    assert Repo.aggregate(Summary, :count) == 0
  end

  test "summary_text never appears in inspect output of the struct or a changeset", %{
    patient: patient
  } do
    summary = save!(patient, "session")
    refute inspect(summary) =~ @marker

    changeset = Summary.changeset(%Summary{}, %{summary_text: @marker, anxiety_score: 7.0})
    refute inspect(changeset) =~ @marker
  end
end
