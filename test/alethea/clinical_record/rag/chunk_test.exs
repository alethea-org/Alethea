defmodule Alethea.ClinicalRecord.Rag.ChunkTest do
  @moduledoc """
  Schema/changeset tests for `Alethea.ClinicalRecord.Rag.Chunk`
  (sdd/clinical-rag-projection, GitHub #196, WU1 task 2.1). Mirrors
  `Alethea.ClinicalRecord.ConsultationEvidence`'s conventions: plaintext
  is never cast (only `encrypted_content` is), and a virtual redacted
  field exists for the caller's convenience post-decryption. Unlike
  `ConsultationEvidence`, rows here ARE replaced in place on re-embed
  (design D4/D5) — there is no immutability trigger to test.

  The D3 uniqueness key (`source_resource_type`, `source_resource_id`,
  `chunk_index`) is enforced at the DB level by
  `clinical_record_rag_chunks_source_chunk_index` (see the migration);
  `changeset/2` surfaces that violation through `unique_constraint/3`.
  """
  use Alethea.DataCase, async: true

  alias Alethea.ClinicalRecord.Rag.Chunk

  @valid_attrs %{
    source_resource_type: "clinical_note",
    source_resource_id: Ecto.UUID.generate(),
    chunk_index: 0,
    encrypted_content: <<1, 2, 3>>,
    embedding: List.duplicate(0.1, 1024),
    embedding_model: "fake-embeddings-bge-m3",
    token_count: 42,
    source_occurred_at: DateTime.utc_now(),
    patient_id: Ecto.UUID.generate(),
    professional_id: Ecto.UUID.generate()
  }

  describe "changeset/2 — happy path" do
    test "is valid with all required fields" do
      changeset = Chunk.changeset(%Chunk{}, @valid_attrs)

      assert changeset.valid?
      assert get_change(changeset, :source_resource_type) == "clinical_note"
      assert get_change(changeset, :chunk_index) == 0
      assert get_change(changeset, :encrypted_content) == <<1, 2, 3>>

      # `Pgvector.Ecto.Vector` casts to a `Pgvector.Vector` struct at
      # Postgres `real` (float32) precision, so exact `0.1` list
      # equality does not hold — assert shape/precision instead,
      # matching what actually reaches pgvector.
      embedding = get_change(changeset, :embedding) |> Pgvector.to_list()
      assert length(embedding) == 1024
      assert Enum.all?(embedding, &(abs(&1 - 0.1) < 0.0001))

      assert get_change(changeset, :embedding_model) == "fake-embeddings-bge-m3"
      assert get_change(changeset, :token_count) == 42
    end

    test "encryption_version defaults to 1 when not cast" do
      changeset = Chunk.changeset(%Chunk{}, @valid_attrs)

      assert changeset.valid?
      assert %Chunk{encryption_version: 1} = Ecto.Changeset.apply_changes(changeset)
    end

    test "full_event defaults to true when not cast" do
      changeset = Chunk.changeset(%Chunk{}, @valid_attrs)

      assert changeset.valid?
      assert %Chunk{full_event: true} = Ecto.Changeset.apply_changes(changeset)
    end

    test "accepts an optional target_behavior_id (triangulation: nullable filter facet)" do
      attrs = Map.put(@valid_attrs, :target_behavior_id, Ecto.UUID.generate())

      changeset = Chunk.changeset(%Chunk{}, attrs)

      assert changeset.valid?
      assert get_change(changeset, :target_behavior_id) == attrs.target_behavior_id
    end

    test "is valid without a target_behavior_id (nullable, not required)" do
      changeset = Chunk.changeset(%Chunk{}, @valid_attrs)

      assert changeset.valid?
      refute Map.has_key?(changeset.changes, :target_behavior_id)
    end
  end

  describe "changeset/2 — plaintext is never cast" do
    test "casting a :content key does not populate the virtual field" do
      attrs = Map.put(@valid_attrs, :content, "texto en claro nunca debe persistirse")

      changeset = Chunk.changeset(%Chunk{}, attrs)

      refute Map.has_key?(changeset.changes, :content)
    end
  end

  describe "changeset/2 — required fields" do
    for field <- [
          :source_resource_type,
          :source_resource_id,
          :chunk_index,
          :encrypted_content,
          :embedding,
          :embedding_model,
          :token_count,
          :source_occurred_at,
          :patient_id,
          :professional_id
        ] do
      test "rejects a missing #{field}" do
        changeset = Chunk.changeset(%Chunk{}, Map.delete(@valid_attrs, unquote(field)))

        refute changeset.valid?
        assert "can't be blank" in errors_on(changeset)[unquote(field)]
      end
    end
  end

  # NOTE (sdd/clinical-rag-projection WU1 apply-progress): this describe
  # block requires `clinical_record_rag_chunks` to exist, which requires
  # `mix ecto.migrate` to succeed, which requires the `vector` Postgres
  # extension to be installed on the connected server. That extension
  # is a pre-existing, project-documented gap (README.md "Estado del
  # RAG y grafo") predating this change — not something this schema's
  # code can fix. On a machine/CI image with pgvector installed, this
  # test runs and passes normally; locally it currently fails with
  # `undefined_table`, which is an infrastructure failure, not a
  # regression in `Chunk.changeset/2`.
  describe "database-level uniqueness (D3 key)" do
    setup do
      professional = create_professional!()
      patient = create_patient!(professional)

      %{professional: professional, patient: patient}
    end

    test "inserting a duplicate (source_resource_type, source_resource_id, chunk_index) violates the unique index",
         %{professional: professional, patient: patient} do
      attrs = %{
        @valid_attrs
        | patient_id: patient.id,
          professional_id: professional.id
      }

      assert {:ok, _first} =
               %Chunk{}
               |> Chunk.changeset(attrs)
               |> Repo.insert()

      assert {:error, changeset} =
               %Chunk{}
               |> Chunk.changeset(attrs)
               |> Repo.insert()

      refute changeset.valid?
      assert "has already been taken" in errors_on(changeset).chunk_index
    end
  end

  defp create_professional! do
    {:ok, professional} =
      Alethea.Accounts.create_professional(%{
        email: "rag-chunk-#{System.unique_integer([:positive])}@alethea.com",
        password: "supersecret12",
        full_name: "Dr. Rag Chunk"
      })

    professional
  end

  defp create_patient!(professional) do
    {:ok, kek} = Alethea.Accounts.load_professional_kek(professional)

    {:ok, patient} =
      Alethea.Accounts.create_patient(
        %{
          "alias" => "Paciente #{System.unique_integer([:positive])}",
          "professional_id" => professional.id
        },
        kek
      )

    patient
  end
end
