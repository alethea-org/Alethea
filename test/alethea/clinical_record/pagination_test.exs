defmodule Alethea.ClinicalRecord.PaginationTest do
  @moduledoc """
  Keyset pagination of clinical notes (`ClinicalRecord.list_clinical_notes_page/3`).
  """
  use Alethea.DataCase, async: true

  import Alethea.RagFixtures

  alias Alethea.Accounts
  alias Alethea.ClinicalRecord
  alias Alethea.ClinicalRecord.ClinicalNote
  alias Alethea.Encryption.PatientVault

  setup do
    professional = create_professional!()
    patient = create_patient!(professional)
    {:ok, kek} = Accounts.load_professional_kek(professional)
    {:ok, dek} = Accounts.load_patient_dek(patient, kek)

    %{professional: professional, patient: patient, dek: dek}
  end

  # Inserts `count` notes, one minute apart, oldest first. Note "Nota N" is
  # newer than "Nota N-1".
  defp insert_notes!(ctx, count, base \\ DateTime.utc_now()) do
    base = DateTime.truncate(base, :second)

    for n <- 1..count do
      insert_note!(ctx, "Nota #{n}", DateTime.add(base, n - count - 1, :minute))
    end
  end

  defp insert_note!(%{professional: professional, patient: patient, dek: dek}, body, at) do
    {:ok, ciphertext} = PatientVault.encrypt(body, dek)

    %ClinicalNote{inserted_at: at}
    |> ClinicalNote.changeset(%{
      patient_id: patient.id,
      professional_id: professional.id,
      encrypted_body: ciphertext
    })
    |> Repo.insert!()
  end

  describe "list_clinical_notes_page/3" do
    test "returns the newest page of 20 decrypted notes and flags more", ctx do
      insert_notes!(ctx, 25)

      assert {:ok, %{entries: entries, has_more?: true}} =
               ClinicalRecord.list_clinical_notes_page(ctx.professional, ctx.patient.id, [])

      assert length(entries) == 20
      assert Enum.map(entries, & &1.body) == Enum.map(25..6//-1, &"Nota #{&1}")
      assert Enum.all?(entries, &(&1.professional.id == ctx.professional.id))
    end

    test "the cursor fetches only the next page, newest first, without overlap", ctx do
      insert_notes!(ctx, 25)

      {:ok, %{entries: first}} =
        ClinicalRecord.list_clinical_notes_page(ctx.professional, ctx.patient.id, limit: 20)

      last = List.last(first)

      assert {:ok, %{entries: second, has_more?: false}} =
               ClinicalRecord.list_clinical_notes_page(ctx.professional, ctx.patient.id,
                 limit: 20,
                 before: {last.inserted_at, last.id}
               )

      assert Enum.map(second, & &1.body) == Enum.map(5..1//-1, &"Nota #{&1}")
    end

    test "honors a custom limit and reports no more at an exact boundary", ctx do
      insert_notes!(ctx, 4)

      assert {:ok, %{entries: [_, _, _, _], has_more?: false}} =
               ClinicalRecord.list_clinical_notes_page(ctx.professional, ctx.patient.id, limit: 4)

      assert {:ok, %{entries: [_, _, _], has_more?: true}} =
               ClinicalRecord.list_clinical_notes_page(ctx.professional, ctx.patient.id, limit: 3)
    end

    test "breaks inserted_at ties by id so pages never skip or repeat notes", ctx do
      at = DateTime.utc_now() |> DateTime.truncate(:second)
      notes = for n <- 1..5, do: insert_note!(ctx, "Empate #{n}", at)
      expected_ids = notes |> Enum.map(& &1.id) |> Enum.sort(:desc)

      {:ok, %{entries: first, has_more?: true}} =
        ClinicalRecord.list_clinical_notes_page(ctx.professional, ctx.patient.id, limit: 2)

      cursor = {List.last(first).inserted_at, List.last(first).id}

      {:ok, %{entries: second, has_more?: true}} =
        ClinicalRecord.list_clinical_notes_page(ctx.professional, ctx.patient.id,
          limit: 2,
          before: cursor
        )

      cursor = {List.last(second).inserted_at, List.last(second).id}

      {:ok, %{entries: third, has_more?: false}} =
        ClinicalRecord.list_clinical_notes_page(ctx.professional, ctx.patient.id,
          limit: 2,
          before: cursor
        )

      assert Enum.map(first ++ second ++ third, & &1.id) == expected_ids
    end

    test "an empty record returns no entries and no more", ctx do
      assert {:ok, %{entries: [], has_more?: false}} =
               ClinicalRecord.list_clinical_notes_page(ctx.professional, ctx.patient.id, [])
    end

    test "denies a professional without access to the patient", ctx do
      insert_notes!(ctx, 1)

      assert {:error, :unauthorized} =
               ClinicalRecord.list_clinical_notes_page(create_professional!(), ctx.patient.id, [])
    end
  end

  describe "list_clinical_notes/2 without pagination" do
    test "still returns every note, newest first", ctx do
      insert_notes!(ctx, 25)

      assert {:ok, notes} = ClinicalRecord.list_clinical_notes(ctx.professional, ctx.patient.id)
      assert Enum.map(notes, & &1.body) == Enum.map(25..1//-1, &"Nota #{&1}")
    end
  end
end
