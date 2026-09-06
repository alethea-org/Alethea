defmodule Alethea.ClinicalRecord.Rag.Indexer do
  @moduledoc """
  Turns eligible `Alethea.ClinicalRecord.Outbox` events into retrievable
  `Alethea.ClinicalRecord.Rag.Chunk` rows for the non-authoritative
  semantic projection (sdd/clinical-rag-projection, GitHub #196, WU2).

  Not wired to `AletheaJobs.ClinicalRecordOutboxWorker` yet — that
  rewiring is WU3 (design section 4). This module is intentionally an
  uncalled, independently testable unit in this batch.

  ## Pipeline (`index_event/1`)

  `eligibility/1` classifies the event → `fetch_and_decrypt/1` loads and
  decrypts the source resource's plaintext under the patient's DEK
  (mirroring `Alethea.ClinicalRecord`'s auth→KEK→DEK ladder, design
  section 0.5: the KEK is server-recoverable in a worker, no session
  needed for ingest) → `chunk/1` splits it → `embed_chunks/1` batch-embeds
  → each chunk's plaintext is re-encrypted under the same DEK →
  `replace_chunks/2` commits the full set in one transaction.

  Ignored (`{:ignore, _}`) and unrecognized (`{:unknown, _}`) events are
  acknowledged (`:ok`) without producing a chunk — see the spec's
  "Recognized-but-ignored" and "Explicit Non-Requirements" (tombstone
  seam) scenarios.
  """

  alias Alethea.Accounts
  alias Alethea.AI

  alias Alethea.ClinicalRecord.{
    AIProposal,
    ClinicalNote,
    ClinicianObservation,
    ConsultationEvidence,
    FunctionalAnalysisDraft
  }

  alias Alethea.ClinicalRecord.Rag.Chunk
  alias Alethea.Encryption.PatientVault
  alias Alethea.Repo

  import Ecto.Query

  @max_tokens 500
  @overlap_ratio 0.15
  # Spanish subword inflation heuristic (design section 3) — a soft
  # bound the embedding model truncates on anyway, so a hand-rolled
  # word-count approximation is deliberately preferred over adding a
  # tokenizer dependency.
  @tokens_per_word 1.35

  @type eligibility_result ::
          {:index, atom()} | {:ignore, atom()} | {:unknown, String.t()}

  @type chunk_piece :: %{
          chunk_index: non_neg_integer(),
          text: String.t(),
          full_event: boolean(),
          token_count: pos_integer()
        }

  # --- 3.1/3.2 eligibility/1 -------------------------------------------

  @doc """
  Classifies a dispatched outbox event's `event` string. One explicit
  clause per spec table row; the trailing catch-all is the tombstone
  seam (#197 adds one clause here with zero restructuring — see the
  spec's "No deletion or tombstone handling" scenario).
  """
  @spec eligibility(String.t()) :: eligibility_result
  def eligibility("clinical_note_created"), do: {:index, :clinical_note}
  def eligibility("consultation_evidence_created"), do: {:index, :consultation_evidence}
  def eligibility("clinician_observation_created"), do: {:index, :clinician_observation}
  def eligibility("clinician_observation_updated"), do: {:index, :clinician_observation}
  def eligibility("ai_proposal_accepted"), do: {:index, :ai_proposal}
  def eligibility("functional_analysis_draft_saved"), do: {:index, :functional_analysis_draft}
  def eligibility("ai_proposal_edited"), do: {:ignore, :not_accepted}
  def eligibility("ai_proposal_discarded"), do: {:ignore, :not_accepted}
  def eligibility("target_behavior_created"), do: {:ignore, :structural_metadata}
  def eligibility(event) when is_binary(event), do: {:unknown, event}

  # --- 3.3/3.4 chunk/1 --------------------------------------------------

  @doc """
  Splits `text` into one or more chunk pieces. Under the ~500-token
  budget yields a single `full_event: true` chunk; over budget,
  sub-splits on paragraph (`\\n{2,}`) then sentence
  (`(?<=[.!?…])\\s+`) boundaries, greedily packing sentences up to the
  budget and prepending ~15% of the previous chunk's trailing text to
  each subsequent chunk (design section 3).
  """
  @spec chunk(String.t()) :: [chunk_piece()]
  def chunk(text) when is_binary(text) do
    total_tokens = token_count(text)

    if total_tokens <= @max_tokens do
      [%{chunk_index: 0, text: text, full_event: true, token_count: total_tokens}]
    else
      text
      |> split_paragraphs()
      |> Enum.flat_map(&split_sentences/1)
      |> pack_sentences()
      |> add_overlap()
      |> Enum.with_index()
      |> Enum.map(fn {chunk_text, index} ->
        %{
          chunk_index: index,
          text: chunk_text,
          full_event: false,
          token_count: token_count(chunk_text)
        }
      end)
    end
  end

  defp token_count(text) do
    text
    |> String.split(~r/\s+/, trim: true)
    |> length()
    |> Kernel.*(@tokens_per_word)
    |> Float.ceil()
    |> trunc()
    |> max(1)
  end

  defp split_paragraphs(text) do
    text
    |> String.split(~r/\n{2,}/)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp split_sentences(paragraph) do
    paragraph
    |> String.split(~r/(?<=[.!?…])\s+/u)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp pack_sentences(sentences) do
    {chunks, last} =
      sentences
      |> Enum.flat_map(&expand_oversized/1)
      |> Enum.reduce({[], ""}, fn sentence, {chunks, current} ->
        candidate = if current == "", do: sentence, else: current <> " " <> sentence

        if token_count(candidate) <= @max_tokens do
          {chunks, candidate}
        else
          {chunks ++ [current], sentence}
        end
      end)

    Enum.reject(chunks ++ [last], &(&1 == ""))
  end

  # A single sentence with no internal paragraph/sentence boundary can
  # still exceed the budget (e.g. one very long run-on line). No
  # linguistic boundary exists to split on, so this falls back to a
  # grapheme-count split (design section 3: "oversized single sentence
  # hard-splits on graphemes").
  defp expand_oversized(sentence) do
    if token_count(sentence) > @max_tokens do
      max_chars = max(trunc(@max_tokens / @tokens_per_word * 5), 1)

      sentence
      |> String.graphemes()
      |> Enum.chunk_every(max_chars)
      |> Enum.map(&Enum.join/1)
    else
      [sentence]
    end
  end

  defp add_overlap([]), do: []

  defp add_overlap([first | rest]) do
    {reversed, _previous} =
      Enum.reduce(rest, {[first], first}, fn chunk_text, {acc, previous} ->
        overlapped = trailing_overlap(previous) <> " " <> chunk_text
        {[overlapped | acc], chunk_text}
      end)

    Enum.reverse(reversed)
  end

  defp trailing_overlap(text) do
    words = String.split(text, ~r/\s+/, trim: true)
    overlap_count = max(round(length(words) * @overlap_ratio), 1)

    words
    |> Enum.take(-overlap_count)
    |> Enum.join(" ")
  end

  # --- 3.5/3.6 embed ------------------------------------------------------

  @doc """
  Batch-embeds `texts` in one call to the configured
  `Alethea.AI.Embeddings` adapter. Returns `{:cancel,
  {:embedding_dimension_mismatch, got, expected}}` when a returned
  vector's length disagrees with `dimensions/0` — a retry cannot fix a
  config mismatch, so the caller should `{:cancel, _}` the job rather
  than burn backoff attempts (design section 3).
  """
  @spec embed_chunks([String.t()]) ::
          {:ok, [[float()]]}
          | {:cancel, {:embedding_dimension_mismatch, non_neg_integer(), pos_integer()}}
          | {:error, term()}
  def embed_chunks(texts) when is_list(texts) do
    adapter = AI.embeddings()

    with {:ok, vectors} <- adapter.embed(texts, []) do
      expected = adapter.dimensions()

      case Enum.find(vectors, fn vector -> length(vector) != expected end) do
        nil -> {:ok, vectors}
        mismatched -> {:cancel, {:embedding_dimension_mismatch, length(mismatched), expected}}
      end
    end
  end

  # --- 3.7/3.8 replace_chunks/2 --------------------------------------------

  @doc """
  Replaces the full chunk set for `{source_resource_type,
  source_resource_id}` in one transaction: delete-by-resource then
  `insert_all`. Idempotent — a retry with the same `chunk_attrs`
  converges to the same set; a concurrent double-run collides on the
  D3 unique index and surfaces as `{:error, _}` (design section 3).
  """
  @spec replace_chunks({String.t(), Ecto.UUID.t()}, [map()]) ::
          {:ok, [Chunk.t()]} | {:error, term()}
  def replace_chunks({resource_type, resource_id}, chunk_attrs) when is_list(chunk_attrs) do
    Repo.transaction(fn ->
      Chunk
      |> where(
        [c],
        c.source_resource_type == ^resource_type and c.source_resource_id == ^resource_id
      )
      |> Repo.delete_all()

      now = DateTime.utc_now() |> DateTime.truncate(:second)

      entries =
        Enum.map(chunk_attrs, fn attrs ->
          attrs
          |> Map.put(:inserted_at, now)
          |> Map.put(:updated_at, now)
        end)

      case Repo.insert_all(Chunk, entries, returning: true) do
        {_count, rows} -> rows
      end
    end)
  end

  # --- 3.9/3.10 index_event/1 -----------------------------------------------

  @doc """
  End-to-end: classifies the event, and for an indexable event fetches
  + decrypts the source resource, chunks it, embeds it, re-encrypts
  each chunk's text under the patient's DEK, and replaces its chunk
  set. Ignored/unknown events are acknowledged without producing a
  chunk. Takes the same 5-key identifier shape
  `Alethea.ClinicalRecord.Outbox.event/2` builds.
  """
  @spec index_event(%{String.t() => String.t()}) ::
          :ok | {:cancel, term()} | {:error, term()}
  def index_event(%{
        "event" => event,
        "resource_type" => resource_type,
        "resource_id" => resource_id,
        "patient_id" => patient_id,
        "professional_id" => professional_id
      }) do
    case eligibility(event) do
      {:index, resource_kind} ->
        index_resource(resource_kind, resource_type, resource_id, patient_id, professional_id)

      {:ignore, _reason} ->
        :ok

      {:unknown, _event} ->
        :ok
    end
  end

  defp index_resource(resource_kind, resource_type, resource_id, patient_id, professional_id) do
    professional = Accounts.get_professional!(professional_id)
    patient = Accounts.get_patient!(patient_id)

    with {:ok, kek} <- Accounts.load_professional_kek(professional),
         {:ok, dek} <- Accounts.load_patient_dek(patient, kek),
         {:ok, plaintext, occurred_at, target_behavior_id} <-
           fetch_and_decrypt(resource_kind, resource_id, dek),
         pieces <- chunk(plaintext),
         {:ok, vectors} <- embed_chunks(Enum.map(pieces, & &1.text)),
         {:ok, chunk_attrs} <-
           encrypt_chunk_attrs(
             pieces,
             vectors,
             dek,
             resource_type,
             resource_id,
             patient_id,
             professional_id,
             occurred_at,
             target_behavior_id
           ),
         {:ok, _rows} <- replace_chunks({resource_type, resource_id}, chunk_attrs) do
      :ok
    end
  end

  defp encrypt_chunk_attrs(
         pieces,
         vectors,
         dek,
         resource_type,
         resource_id,
         patient_id,
         professional_id,
         occurred_at,
         target_behavior_id
       ) do
    embedding_model = AI.embeddings().model()

    pieces
    |> Enum.zip(vectors)
    |> Enum.reduce_while({:ok, []}, fn {piece, vector}, {:ok, acc} ->
      case PatientVault.encrypt(piece.text, dek) do
        {:ok, ciphertext} ->
          attrs = %{
            source_resource_type: resource_type,
            source_resource_id: resource_id,
            chunk_index: piece.chunk_index,
            encrypted_content: ciphertext,
            embedding: vector,
            embedding_model: embedding_model,
            token_count: piece.token_count,
            full_event: piece.full_event,
            source_occurred_at: occurred_at,
            patient_id: patient_id,
            professional_id: professional_id,
            target_behavior_id: target_behavior_id
          }

          {:cont, {:ok, [attrs | acc]}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, attrs} -> {:ok, Enum.reverse(attrs)}
      error -> error
    end
  end

  # `clinical_notes.inserted_at`/`functional_analysis_drafts.updated_at`
  # are `:utc_datetime` (second precision), but
  # `Chunk.source_occurred_at` is `:utc_datetime_usec` — `insert_all/3`
  # dumps the value as-is (no changeset cast), so the precision must be
  # widened explicitly or `Ecto.Type.check_usec!/2` rejects it.
  defp to_usec(%DateTime{microsecond: {value, _precision}} = dt) do
    %{dt | microsecond: {value, 6}}
  end

  # Loads the source resource by its polymorphic (resource_type,
  # resource_id) pair and decrypts its free text under the patient's
  # DEK. Returns `{:ok, plaintext, occurred_at, target_behavior_id}` —
  # `occurred_at` and `target_behavior_id` vary by resource shape
  # (some schemas have no independent historical timestamp or filter
  # facet), so this is the single seam that normalizes them.
  defp fetch_and_decrypt(:clinical_note, resource_id, dek) do
    case Repo.get(ClinicalNote, resource_id) do
      nil ->
        {:error, :not_found}

      note ->
        with {:ok, text} <- PatientVault.decrypt(note.encrypted_body, dek) do
          {:ok, text, to_usec(DateTime.from_naive!(note.inserted_at, "Etc/UTC")), nil}
        end
    end
  end

  defp fetch_and_decrypt(:consultation_evidence, resource_id, dek) do
    case Repo.get(ConsultationEvidence, resource_id) do
      nil ->
        {:error, :not_found}

      evidence ->
        with {:ok, text} <- PatientVault.decrypt(evidence.encrypted_excerpt, dek) do
          {:ok, text, evidence.occurred_at, evidence.target_behavior_id}
        end
    end
  end

  defp fetch_and_decrypt(:clinician_observation, resource_id, dek) do
    case Repo.get(ClinicianObservation, resource_id) do
      nil ->
        {:error, :not_found}

      observation ->
        with {:ok, text} <- PatientVault.decrypt(observation.encrypted_body, dek) do
          {:ok, text, observation.occurred_at, observation.target_behavior_id}
        end
    end
  end

  defp fetch_and_decrypt(:ai_proposal, resource_id, dek) do
    case Repo.get(AIProposal, resource_id) do
      nil ->
        {:error, :not_found}

      proposal ->
        with {:ok, text} <- PatientVault.decrypt(proposal.encrypted_text, dek) do
          {:ok, text, proposal.occurred_at, proposal.target_behavior_id}
        end
    end
  end

  defp fetch_and_decrypt(:functional_analysis_draft, resource_id, dek) do
    case Repo.get(FunctionalAnalysisDraft, resource_id) do
      nil ->
        {:error, :not_found}

      draft ->
        with {:ok, text} <- PatientVault.decrypt(draft.encrypted_body, dek) do
          {:ok, text, to_usec(DateTime.from_naive!(draft.updated_at, "Etc/UTC")),
           draft.target_behavior_id}
        end
    end
  end
end
