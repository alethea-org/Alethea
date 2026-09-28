defmodule Alethea.ClinicalRecord.EvidenceSourceTest do
  @moduledoc """
  Tests for `Alethea.ClinicalRecord.EvidenceSource.fetch/4` support of
  `session_transcript` sources (sdd/audio-evidence-citation-328, GitHub
  #328, Phase 3, design AD4/R7). `clinical_note`/`message` fetch is
  already covered indirectly via `Alethea.ClinicalRecordTest`'s
  `cite_evidence_source/4` tests.
  """
  use Alethea.DataCase, async: true

  alias Alethea.Accounts
  alias Alethea.ClinicalRecord
  alias Alethea.ClinicalRecord.EvidenceSource

  setup do
    professional = create_professional!()
    patient = create_patient!(professional)
    %{professional: professional, patient: patient}
  end

  describe "fetch/4 — session_transcript (R7)" do
    test "returns the decrypted spans, occurred_at set to recorded_at, and joined content", %{
      professional: professional,
      patient: patient
    } do
      recorded_at = ~U[2026-09-20 15:00:00.000000Z]

      spans = [
        %{start: 0.0, end: 3.0, speaker: "therapist", text: "Como se siente hoy?"},
        %{start: 3.0, end: 6.0, speaker: "patient", text: "Un poco mejor que ayer."}
      ]

      {:ok, transcript} =
        ClinicalRecord.create_session_transcript(professional, patient.id, %{
          spans: spans,
          recorded_at: recorded_at
        })

      keyring = keyring_for!(professional, patient)

      assert {:ok, %EvidenceSource{} = source} =
               EvidenceSource.fetch("session_transcript", transcript.id, patient.id, keyring)

      assert source.kind == :session_transcript
      assert source.id == transcript.id
      assert source.occurred_at == recorded_at
      assert source.spans == spans
      assert source.content == "Como se siente hoy?\nUn poco mejor que ayer."
    end

    test "a missing id and a foreign-patient id both return not_found (table-driven)", %{
      professional: professional,
      patient: patient
    } do
      other_patient = create_patient!(professional)

      {:ok, foreign_transcript} =
        ClinicalRecord.create_session_transcript(professional, other_patient.id, %{
          spans: [%{start: 0.0, end: 1.0, speaker: "patient", text: "Ajeno"}],
          recorded_at: DateTime.utc_now()
        })

      keyring = keyring_for!(professional, patient)

      for source_id <- [Ecto.UUID.generate(), foreign_transcript.id] do
        assert {:error, :not_found} =
                 EvidenceSource.fetch("session_transcript", source_id, patient.id, keyring)
      end
    end
  end

  defp keyring_for!(professional, patient) do
    {:ok, kek} = Accounts.load_professional_kek(professional)
    {:ok, patient_dek} = Accounts.load_patient_dek(patient, kek)
    {:ok, clinical_record_dek} = Accounts.ensure_clinical_record_dek(patient, kek)
    %{patient_dek: patient_dek, clinical_record_dek: clinical_record_dek}
  end

  defp create_professional! do
    {:ok, professional} =
      Accounts.create_professional(%{
        email: "evidence-source-#{System.unique_integer([:positive])}@alethea.com",
        password: "supersecret12",
        full_name: "Dr. Evidence Source"
      })

    professional
  end

  defp create_patient!(professional) do
    {:ok, kek} = Accounts.load_professional_kek(professional)

    {:ok, patient} =
      Accounts.create_patient(
        %{
          "alias" => "Paciente #{System.unique_integer([:positive])}",
          "professional_id" => professional.id
        },
        kek
      )

    patient
  end
end
