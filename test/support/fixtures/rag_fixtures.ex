defmodule Alethea.RagFixtures do
  @moduledoc """
  Shared seeding helpers for RAG/consultation tests: real `Retrieval` runs
  over seeded chunks, deterministic embedding stubs via Mox, and Oban
  pending-job seeding. Imported by the test modules that need them.

  `stub_query_embedding/1` and `expect_embeddings_never_called/0` swap the
  global `:ai_embeddings` adapter slot through `Application.put_env/3`, so
  a test module that calls either MUST be `async: false` — otherwise it
  races every concurrent file that reads that slot.
  """

  import Ecto.Query
  import ExUnit.Callbacks
  import Mox

  alias Alethea.Accounts
  alias Alethea.ClinicalRecord
  alias Alethea.ClinicalRecord.Rag.Consultation.Fake
  alias Alethea.ClinicalRecord.Rag.Consultation.HypothesisPolicy
  alias Alethea.ClinicalRecord.Rag.Indexer
  alias Alethea.Encryption.PatientVault
  alias Alethea.Repo
  alias AletheaJobs.ClinicalRecordOutboxWorker

  def near_vector, do: [1.0 | List.duplicate(0.0, 1023)]

  def stub_query_embedding(vector) do
    Application.put_env(:alethea, :ai_embeddings, Alethea.AI.EmbeddingsMock, persistent: true)

    on_exit(fn ->
      Application.put_env(:alethea, :ai_embeddings, Alethea.AI.Embeddings.Fake, persistent: true)
    end)

    Alethea.AI.EmbeddingsMock
    |> stub(:embed, fn _query, [] -> {:ok, vector} end)
    |> stub(:dimensions, fn -> 1024 end)
    |> stub(:model, fn -> "fake-embeddings-bge-m3" end)
  end

  def expect_embeddings_never_called do
    Application.put_env(:alethea, :ai_embeddings, Alethea.AI.EmbeddingsMock, persistent: true)

    on_exit(fn ->
      Application.put_env(:alethea, :ai_embeddings, Alethea.AI.Embeddings.Fake, persistent: true)
    end)

    expect(Alethea.AI.EmbeddingsMock, :embed, 0, fn _query, [] -> :never end)
  end

  def insert_pending_job!(professional, patient) do
    {:ok, _job} =
      %{
        "event" => "clinical_note_created",
        "resource_type" => "clinical_note",
        "resource_id" => Ecto.UUID.generate(),
        "patient_id" => patient.id,
        "professional_id" => professional.id
      }
      |> ClinicalRecordOutboxWorker.new()
      |> Oban.insert()
  end

  @doc """
  Seeds one retrievable chunk for `patient`, encrypted under their DEK.

  `opts` covers the facets a retrieval/render test needs to vary:

    * `:source_resource_type` - defaults to `"clinical_note"`
    * `:target_behavior_id` - defaults to `nil` (no review link)
    * `:occurred_at` - defaults to `DateTime.utc_now/0`

  """
  def insert_chunk!(professional, patient, text, vector, opts \\ []) do
    resource_type = Keyword.get(opts, :source_resource_type, "clinical_note")
    target_behavior_id = Keyword.get(opts, :target_behavior_id)
    occurred_at = Keyword.get(opts, :occurred_at, DateTime.utc_now())

    resource_id = Ecto.UUID.generate()
    {:ok, kek} = Accounts.load_professional_kek(professional)
    {:ok, dek} = Accounts.load_patient_dek(patient, kek)
    {:ok, ciphertext} = PatientVault.encrypt(text, dek)

    attrs = [
      %{
        source_resource_type: resource_type,
        source_resource_id: resource_id,
        chunk_index: 0,
        encrypted_content: ciphertext,
        embedding: vector,
        embedding_model: "fake-embeddings-bge-m3",
        token_count: 10,
        full_event: true,
        source_occurred_at: occurred_at,
        target_behavior_id: target_behavior_id,
        patient_id: patient.id,
        professional_id: professional.id
      }
    ]

    {:ok, _rows} = Indexer.replace_chunks({resource_type, resource_id}, attrs)
    resource_id
  end

  @outbox_worker "AletheaJobs.ClinicalRecordOutboxWorker"

  @doc """
  Drops the patient's pending ClinicalRecord outbox jobs.

  Creating a domain row (a target behavior, a note) enqueues one outbox
  job, and `Rag.Retrieval.freshness/1` counts those as a pending index —
  so `Rag.Consultation.Live` answers `:stale` before it ever retrieves.
  Tests that seed their chunks directly through `insert_chunk!/5` call
  this to drop the enqueued-but-irrelevant jobs.
  """
  def clear_pending_outbox!(patient) do
    Oban.Job
    |> where([j], j.worker == ^@outbox_worker)
    |> where([j], fragment("? ->> 'patient_id' = ?", j.args, ^to_string(patient.id)))
    |> Repo.delete_all()
  end

  def create_target_behavior!(professional, patient) do
    {:ok, target_behavior} =
      ClinicalRecord.create_target_behavior(
        professional,
        patient.id,
        "Conducta objetivo #{System.unique_integer([:positive])}"
      )

    target_behavior
  end

  def create_professional! do
    {:ok, professional} =
      Accounts.create_professional(%{
        email: "consultation-live-#{System.unique_integer([:positive])}@alethea.com",
        password: "supersecret12",
        full_name: "Dr. Consultation Live"
      })

    professional
  end

  @doc """
  A real `%Hypothesis{}`, built through `HypothesisPolicy.evaluate/2` —
  the sole constructor, never hand-rolled — over `Fake.canned_results/0`
  (#235b/AD2), so `Consultation.Fake`'s sources and this hypothesis cite
  the exact same fragment. `test/**` sits outside the Hypothesis Wiring
  Gate's `lib/**` scan glob, so this call site does not count toward it.
  """
  def canned_hypothesis! do
    {:ok, hypothesis} =
      HypothesisPolicy.evaluate(
        "Podría existir una relación entre las caminatas pactadas y la mejoría del ánimo.",
        Fake.canned_results()
      )

    hypothesis
  end

  def set_fake_hypothesis(hypothesis) do
    Application.put_env(:alethea, :consultation_fake_hypothesis, hypothesis, persistent: true)
  end

  def reset_fake_hypothesis do
    Application.delete_env(:alethea, :consultation_fake_hypothesis)
  end

  def create_patient!(professional) do
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
