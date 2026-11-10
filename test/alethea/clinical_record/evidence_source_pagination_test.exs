defmodule Alethea.ClinicalRecord.EvidenceSourcePaginationTest do
  @moduledoc """
  Keyset pagination of citable evidence sources
  (`EvidenceSource.list_page/3`, `ClinicalRecord.list_evidence_sources_page/3`).
  Pages must follow exactly the `EvidenceSource.list/2` order: inbound messages
  first, then outbound messages and clinical notes, each newest first.
  """
  use Alethea.DataCase, async: true

  import Alethea.RagFixtures

  alias Alethea.Accounts
  alias Alethea.Clinical, as: Journaling
  alias Alethea.ClinicalRecord
  alias Alethea.ClinicalRecord.ClinicalNote
  alias Alethea.ClinicalRecord.EvidenceSource
  alias Alethea.Encryption.PatientVault

  setup do
    professional = create_professional!()
    patient = create_patient!(professional)
    {:ok, kek} = Accounts.load_professional_kek(professional)
    {:ok, patient_dek} = Accounts.load_patient_dek(patient, kek)
    {:ok, clinical_record_dek} = Accounts.ensure_clinical_record_dek(patient, kek)
    keyring = %{patient_dek: patient_dek, clinical_record_dek: clinical_record_dek}

    %{professional: professional, patient: patient, keyring: keyring}
  end

  defp at(minutes),
    do: DateTime.add(~U[2026-06-01 12:00:00Z], minutes, :minute)

  defp insert_message!(ctx, direction, content, occurred_at) do
    {:ok, ciphertext} = PatientVault.encrypt(content, ctx.keyring.patient_dek)

    %Journaling.Message{}
    |> Journaling.Message.changeset(%{
      direction: direction,
      behavior_type: "spontaneous",
      encrypted_content: ciphertext,
      encryption_version: 1,
      timestamp: occurred_at,
      patient_id: ctx.patient.id
    })
    |> Repo.insert!()
  end

  defp insert_note!(ctx, body, occurred_at) do
    {:ok, ciphertext} = PatientVault.encrypt(body, ctx.keyring.patient_dek)

    %ClinicalNote{inserted_at: occurred_at}
    |> ClinicalNote.changeset(%{
      patient_id: ctx.patient.id,
      professional_id: ctx.professional.id,
      encrypted_body: ciphertext
    })
    |> Repo.insert!()
  end

  # A mixed record: interleaved inbound/outbound messages and notes, with
  # several timestamp ties inside and across tables.
  defp insert_mixed_record!(ctx) do
    for n <- 1..7, do: insert_message!(ctx, "inbound", "Entrante #{n}", at(rem(n, 3)))
    for n <- 1..4, do: insert_message!(ctx, "outbound", "Saliente #{n}", at(rem(n, 2)))
    for n <- 1..5, do: insert_note!(ctx, "Nota #{n}", at(rem(n, 2)))
    :ok
  end

  defp collect_pages(ctx, limit, cursor \\ nil, acc \\ []) do
    opts = if cursor, do: [limit: limit, before: cursor], else: [limit: limit]

    {:ok, %{entries: entries, has_more?: has_more?}} =
      EvidenceSource.list_page(ctx.patient.id, ctx.keyring, opts)

    assert length(entries) <= limit
    acc = acc ++ entries

    if has_more? do
      collect_pages(ctx, limit, EvidenceSource.cursor(List.last(entries)), acc)
    else
      acc
    end
  end

  describe "EvidenceSource.list_page/3" do
    test "walking every page reproduces list/2 exactly, for several page sizes", ctx do
      insert_mixed_record!(ctx)
      {:ok, all} = EvidenceSource.list(ctx.patient.id, ctx.keyring)
      assert length(all) == 16

      for limit <- [1, 2, 3, 7, 16, 20] do
        assert collect_pages(ctx, limit) == all, "page size #{limit} diverged from list/2"
      end
    end

    test "defaults to 20 entries and flags more", ctx do
      for n <- 1..25, do: insert_message!(ctx, "inbound", "Entrante #{n}", at(n))

      assert {:ok, %{entries: entries, has_more?: true}} =
               EvidenceSource.list_page(ctx.patient.id, ctx.keyring, [])

      assert length(entries) == 20
      assert Enum.map(entries, & &1.content) == Enum.map(25..6//-1, &"Entrante #{&1}")
    end

    test "a cursor at the last inbound message continues with notes and outbound messages",
         ctx do
      insert_message!(ctx, "inbound", "Entrante", at(0))
      insert_note!(ctx, "Nota reciente", at(5))
      insert_message!(ctx, "outbound", "Saliente", at(1))

      {:ok, %{entries: [inbound], has_more?: true}} =
        EvidenceSource.list_page(ctx.patient.id, ctx.keyring, limit: 1)

      assert inbound.content == "Entrante"

      assert {:ok, %{entries: rest, has_more?: false}} =
               EvidenceSource.list_page(ctx.patient.id, ctx.keyring,
                 limit: 5,
                 before: EvidenceSource.cursor(inbound)
               )

      assert Enum.map(rest, & &1.content) == ["Nota reciente", "Saliente"]
    end

    test "an empty record returns no entries and no more", ctx do
      assert {:ok, %{entries: [], has_more?: false}} =
               EvidenceSource.list_page(ctx.patient.id, ctx.keyring, [])
    end

    test "never returns another patient's sources", ctx do
      other = create_patient!(ctx.professional)
      insert_message!(%{ctx | patient: other}, "inbound", "Ajeno", at(0))
      insert_message!(ctx, "inbound", "Propio", at(0))

      assert {:ok, %{entries: [%{content: "Propio"}], has_more?: false}} =
               EvidenceSource.list_page(ctx.patient.id, ctx.keyring, [])
    end
  end

  describe "ClinicalRecord.list_evidence_sources_page/3" do
    test "returns the first page for an authorized professional", ctx do
      for n <- 1..21, do: insert_note!(ctx, "Nota #{n}", at(n))

      assert {:ok, %{entries: entries, has_more?: true}} =
               ClinicalRecord.list_evidence_sources_page(ctx.professional, ctx.patient.id, [])

      assert length(entries) == 20
      assert hd(entries).content == "Nota 21"
    end

    test "denies a professional without access to the patient", ctx do
      assert {:error, :unauthorized} =
               ClinicalRecord.list_evidence_sources_page(
                 create_professional!(),
                 ctx.patient.id,
                 []
               )
    end
  end

  describe "ClinicalRecord.get_evidence_source/4" do
    test "fetches one listed source and rejects foreign or missing ids", ctx do
      note = insert_note!(ctx, "Nota citable", at(0))

      assert {:ok, %EvidenceSource{kind: :clinical_note, content: "Nota citable"}} =
               ClinicalRecord.get_evidence_source(
                 ctx.professional,
                 ctx.patient.id,
                 "clinical_note",
                 note.id
               )

      assert {:error, :not_found} =
               ClinicalRecord.get_evidence_source(
                 ctx.professional,
                 ctx.patient.id,
                 "message",
                 Ecto.UUID.generate()
               )

      assert {:error, :unauthorized} =
               ClinicalRecord.get_evidence_source(
                 create_professional!(),
                 ctx.patient.id,
                 "clinical_note",
                 note.id
               )
    end
  end
end
