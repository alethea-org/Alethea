defmodule Alethea.ClinicalRecord.SourceRefTest do
  @moduledoc """
  Unit tests for `Alethea.ClinicalRecord.SourceRef` (PR2b, part of
  sdd/alethea/issue-195-clinical-review-workbench, GitHub #195, design's
  "SourceRef adapter" section). Read-only, no-FK adapter resolving
  `source_kind` + `source_id` into display metadata — never ciphertext,
  never plaintext excerpt text (design: "metadata only").
  """
  use Alethea.DataCase, async: true

  alias Alethea.Accounts
  alias Alethea.Clinical, as: Journaling
  alias Alethea.ClinicalRecord
  alias Alethea.ClinicalRecord.SourceRef

  setup do
    professional = create_professional!()
    patient = create_patient!(professional)

    %{professional: professional, patient: patient}
  end

  describe "resolve/2 — clinical_note source" do
    test "found: returns kind, occurred_at (inserted_at), empty reference map", %{
      professional: professional,
      patient: patient
    } do
      {:ok, note} = ClinicalRecord.create_clinical_note(professional, patient.id, "Nota citada")

      assert {:ok, %{kind: :clinical_note, occurred_at: occurred_at, reference: %{}}} =
               SourceRef.resolve("clinical_note", note.id)

      assert occurred_at == note.inserted_at
    end

    test "missing row: returns :unavailable", %{} do
      assert SourceRef.resolve("clinical_note", Ecto.UUID.generate()) == :unavailable
    end
  end

  describe "resolve/2 — message source" do
    test "found: returns kind, occurred_at (timestamp), and behavior_type/direction/timestamp reference",
         %{professional: professional, patient: patient} do
      {:ok, kek} = Accounts.load_professional_kek(professional)
      {:ok, dek} = Accounts.load_patient_dek(patient, kek)

      {:ok, message} =
        Journaling.save_message(patient, "Mensaje citado", dek, "inbound", "elicited")

      assert {:ok,
              %{
                kind: :message,
                occurred_at: occurred_at,
                reference: %{behavior_type: "elicited", direction: "inbound", timestamp: ts}
              }} = SourceRef.resolve("message", message.id)

      assert occurred_at == message.timestamp
      assert ts == message.timestamp
    end

    test "missing row: returns :unavailable" do
      assert SourceRef.resolve("message", Ecto.UUID.generate()) == :unavailable
    end
  end

  describe "resolve/2 — degradation (design A3: excerpt already stored, source metadata is best-effort)" do
    test "unknown source_kind: returns :unavailable" do
      assert SourceRef.resolve("diagnosis", Ecto.UUID.generate()) == :unavailable
    end

    test "malformed UUID: returns :unavailable, does not raise" do
      assert SourceRef.resolve("clinical_note", "not-a-uuid") == :unavailable
      assert SourceRef.resolve("message", "not-a-uuid") == :unavailable
    end
  end

  describe "resolve_many/1 — batched, no N+1" do
    test "resolves a mixed list of clinical_note/message/missing/malformed refs in one call", %{
      professional: professional,
      patient: patient
    } do
      {:ok, kek} = Accounts.load_professional_kek(professional)
      {:ok, dek} = Accounts.load_patient_dek(patient, kek)

      {:ok, note} = ClinicalRecord.create_clinical_note(professional, patient.id, "Nota A")

      {:ok, message} =
        Journaling.save_message(patient, "Mensaje B", dek, "inbound", "spontaneous")

      missing_id = Ecto.UUID.generate()

      refs = [
        {"clinical_note", note.id},
        {"message", message.id},
        {"clinical_note", missing_id},
        {"clinical_note", "not-a-uuid"}
      ]

      resolved = SourceRef.resolve_many(refs)

      assert %{kind: :clinical_note} = elem(Map.fetch!(resolved, {"clinical_note", note.id}), 1)
      assert %{kind: :message} = elem(Map.fetch!(resolved, {"message", message.id}), 1)
      assert Map.fetch!(resolved, {"clinical_note", missing_id}) == :unavailable
      assert Map.fetch!(resolved, {"clinical_note", "not-a-uuid"}) == :unavailable
    end

    test "empty list returns empty map" do
      assert SourceRef.resolve_many([]) == %{}
    end
  end

  defp create_professional! do
    {:ok, professional} =
      Accounts.create_professional(%{
        email: "source-ref-#{System.unique_integer([:positive])}@alethea.com",
        password: "supersecret12",
        full_name: "Dr. Source Ref"
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
