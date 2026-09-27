# Design: Session transcript RAG ingestion and chunking (#320)

**Inputs:** `proposal.md` (decided: D-A, D-B, D1–D5), `spec.md` (R-X1, R-X2, R-X3 binding)
**Status:** design complete. 9 ADs, 3 findings. **Forecast is about 550 lines, so 2 chained PRs (about 258 + about 290).**

---

## Technical Approach

Additive ingest branch inside the existing `Rag.Indexer` pipeline (`indexer.ex:308-337`). The `:session_transcript` kind gets its own fetch clause, which returns **spans** where the other kinds return text. A kind-dispatched `pieces_for/2` sends spans to a new pure `chunk_spans/1` and sends text to the unchanged `chunk/1`. Pieces carry three optional keys. `encrypt_chunk_attrs` copies those keys into every row, and the value is `nil` for the six existing kinds. `replace_chunks/2` stays untouched.

```
Outbox "session_transcript_created" (clinical_record.ex:459, 5 identifier keys)
  → ClinicalRecordOutboxWorker.perform/1 → Indexer.index_event/1
  → eligibility/1 = {:index, :session_transcript}                        (NEW, before :84)
  → index_resource/5: KEK → patient DEK                                  (:311-312)
  → fetch_and_decrypt(:session_transcript, …)                            (NEW clause)
       Repo.get(SessionTranscript) → resolve_dek(transcript.encryption_version=2)
       → PatientVault.decrypt(encrypted_spans) → SessionTranscriptContent.parse/1
       ⇒ {:ok, spans, recorded_at, nil, 2, cr_dek}
  → pieces_for(:session_transcript, spans) = chunk_spans(spans)          (NEW)
       reject blank → chunk/1 per span → inherit speaker/start*1.0/end*1.0 → renumber
  → warn_if_empty(:session_transcript, resource_id, pieces)              (R-X1)
  → embed_pieces(pieces)   [] ⇒ {:ok, []} (adapter never called)         (NEW guard)
  → encrypt_chunk_attrs(...)  + speaker/audio_start_seconds/audio_end_seconds
  → replace_chunks({type,id}, attrs)  delete_all + insert_all            (:247-269, unchanged)
```

---

## Architecture Decisions

| # | Decision | Rejected | Rationale |
|---|---|---|---|
| AD1 | **Float normalization happens in `chunk_spans/1`** (`span.start * 1.0`, `span.end * 1.0`), not in the changeset | Cast in `Chunk.changeset/2`. Normalize in `encrypt_chunk_attrs` | `replace_chunks/2` writes through `Repo.insert_all` (`indexer.ex:265`), which **bypasses the changeset**. Orchestrator verified: `Ecto.Type.dump(:float, 12)` → `:error`, `dump(:float, 12.0)` → `{:ok, 12.0}`, `cast(:float, 12)` → `{:ok, 12.0}`. Integers are legal input because spans are typed `number()` (`session_transcript_content.ex:20`) and survive the JSON round-trip as integers (`:108-115`). Normalizing at piece construction means the pure unit test proves it and every downstream step sees floats. Same class of bug as `to_usec/1` (`indexer.ex:398-405`). **Required tests:** unit (`start: 12` → `12.0`, checked with `is_float`) and integration (integer span through `index_event/1` persists) |
| AD2 | `chunk_spans/1` is **public** in `Indexer`, `@doc`'d, and reuses `chunk/1` per span | Private. Separate module `Rag.SpanChunker` | Mirrors the public `chunk/1` (`:96`), so it can be unit-tested directly. A new module would have to expose the private splitter helpers (`:120-198`) or duplicate them. The one-module-per-file rule is respected either way |
| AD3 | Fetch returns spans in the existing "plaintext" slot of the 6-tuple. `pieces_for/2` dispatches on `resource_kind` | Tagged `{:spans, _}` payload. A separate `index_transcript/5` pipeline | Only one clause and one call site change. `resource_kind` is already in scope (`:308`). The six text clauses (`:417-506`) are byte-identical |
| AD4 | `full_event` is per piece: `true` when the whole turn fits in one piece, `false` for sub-pieces (inherited from `chunk/1`) | Always `true` | Keeps the meaning "piece == whole source unit", with the unit being the turn (spec: one turn → one chunk, `full_event: true`) |
| AD5 | `chunk_index` runs **globally** across spans, `0..n-1`, in span order | Per-span indices | The unique key `(type, id, chunk_index)` (`20260904000131:81-85`) requires global uniqueness |
| AD6 | Parse failure → `{:cancel, :malformed_transcript}` | Pass `{:error, :malformed}` through | Any `{:error, _}` other than `:not_found` gets retried by the worker (`clinical_record_outbox_worker.ex:63`). A corrupt blob is permanent, so retrying only burns 5 attempts |
| AD7 | Zero pieces → skip embedding, still call `replace_chunks(ref, [])` → `:ok` | Call `embed_chunks([])` | Fake returns `[]` safely (`fake.ex:41-43`), but Ollama forwards an empty batch (`ollama.ex:42-44`) with undefined behavior. `replace_chunks(_, [])` purges any stale set, which keeps the result idempotent |
| AD8 | **Three CHECK constraints, no new index** (see Migration) | No checks. Btree on `speaker` | `insert_all` skips the changeset, so the DB is the only write-path guard. Precedent: `consultation_evidences.source_kind_must_be_valid` (`20260831213217:51-52`). A 2-value speaker column is low cardinality, and #328 filters inside patient-scoped HNSW retrieval, so a speaker index would not be used. YAGNI |
| AD9 | No speaker prefix in the embedded text | `"Paciente: …"` | Proposal recommendation. Chunk text stays verbatim for citation, and the speaker lives in the column |

---

## Migration (apply generates via `mix ecto.gen.migration add_transcript_metadata_to_rag_chunks`)

```elixir
def change do
  alter table(:clinical_record_rag_chunks) do
    add :speaker, :string                     # plaintext by design (D3)
    add :audio_start_seconds, :float          # double precision (D1)
    add :audio_end_seconds, :float
  end

  create constraint(:clinical_record_rag_chunks, :speaker_must_be_valid,
           check: "speaker IS NULL OR speaker IN ('patient', 'therapist')")

  # Transcript chunks carry all three; every other kind carries none.
  create constraint(:clinical_record_rag_chunks, :transcript_metadata_consistent,
           check: """
           (source_resource_type = 'session_transcript') = (speaker IS NOT NULL)
           AND (speaker IS NULL) = (audio_start_seconds IS NULL)
           AND (speaker IS NULL) = (audio_end_seconds IS NULL)
           """)

  create constraint(:clinical_record_rag_chunks, :audio_bounds_ordered,
           check: "audio_start_seconds <= audio_end_seconds")
end
```

This is reversible through `change`, and rollback drops the constraints before the columns. The type-coupled check is **safe on existing data**: no `session_transcript` chunk can exist in any environment yet, because the catch-all at `indexer.ex:84` acknowledged those events without indexing. It gives #328 a DB guarantee for R-X3: every transcript chunk has a speaker.

---

## Findings

- **F1**: `test/alethea/clinical_record/rag/retrieval_test.exs:457-464` seeds a `"session_transcript"` chunk through its **local** `insert_chunk!/5` (`:667-691`) with no speaker. `transcript_metadata_consistent` would reject that row, so the helper has to add `speaker/start/end` when `resource_type == "session_transcript"`. This is a test-only edit and does not break D-B, which scopes out code only.
- **F2**: `Indexer` has no `require Logger` today. R-X1 needs one. `config/test.exs:24` sets `level: :warning`, so `capture_log/1` sees the warning without extra config.
- **F3**: AC4 needs no production code. `Retention.legally_delete_record/2` (`retention.ex:162`) enqueues `Outbox.tombstone_event` (`:274-277`). `retention_test.exs:325-355` already proves the enqueue. The indexer purge branch is at `indexer.ex:291-295`. #320 only needs the end-to-end chunk-count proof.

---

## Interfaces

```elixir
@type span_chunk_piece :: %{
        chunk_index: non_neg_integer(), text: String.t(), full_event: boolean(),
        token_count: pos_integer(), speaker: String.t(),
        audio_start_seconds: float(), audio_end_seconds: float()
      }

@spec chunk_spans([SessionTranscriptContent.span()]) :: [span_chunk_piece()]
def chunk_spans(spans) when is_list(spans) do
  spans
  |> Enum.reject(&(String.trim(&1.text) == ""))                       # D2
  |> Enum.flat_map(fn span ->
    Enum.map(chunk(span.text), fn piece ->
      Map.merge(piece, %{speaker: span.speaker,                        # R-X2: verbatim,
                         audio_start_seconds: span.start * 1.0,        # no interpolation
                         audio_end_seconds: span.end * 1.0})           # AD1
    end)
  end)
  |> Enum.with_index()
  |> Enum.map(fn {piece, index} -> %{piece | chunk_index: index} end) # AD5
end

defp warn_if_empty(:session_transcript, resource_id, []) do
  Logger.warning("rag indexer: session_transcript #{resource_id} produced zero chunks")
end
defp warn_if_empty(_kind, _resource_id, _pieces), do: :ok
```

The warning is written inside `index_resource/5` as `:ok <- warn_if_empty(...)`. The message includes only `resource_id`. It never includes span text, speaker, or `patient_id` (R-X1).

In `encrypt_chunk_attrs/10` (`:370-384`), the new keys are `speaker: Map.get(piece, :speaker)`, `audio_start_seconds: Map.get(piece, :audio_start_seconds)`, and `audio_end_seconds: Map.get(piece, :audio_end_seconds)`. These are plain maps, not structs, so `Map.get/2` is allowed. Every row carries the same keys, so `insert_all` gets a uniform header.

The fetch clause sets `occurred_at = transcript.recorded_at`, which is already `utc_datetime_usec` (`session_transcript.ex:36`), so no `to_usec`. It sets `target_behavior_id = nil`.

`Chunk` (`chunk.ex:45-66`, `:75-105`) gains 3 fields and 3 cast entries, plus `validate_inclusion(:speaker, SessionTranscriptContent.speakers())`.

---

## File Changes and Line Forecast

| File | Action | PR | Est. lines |
|---|---|---|---|
| `priv/repo/migrations/<ts>_add_transcript_metadata_to_rag_chunks.exs` | Create | 1 | 35 |
| `lib/alethea/clinical_record/rag/chunk.ex` | Modify | 1 | 15 |
| `lib/alethea/clinical_record/rag/indexer.ex`: `chunk_spans/1` + type | Modify | 1 | 45 |
| `lib/alethea/clinical_record/rag/indexer.ex`: eligibility, fetch, `pieces_for`, warn, embed guard, attrs, Logger | Modify | 2 | 60 |
| **Prod subtotal** | | | **155** |
| `test/alethea/clinical_record/rag/chunk_test.exs`: cast, inclusion, 3 DB checks | Modify | 1 | 45 |
| `test/support/fixtures/rag_fixtures.ex`: `:speaker/:audio_start_seconds/:audio_end_seconds` opts | Modify | 1 | 10 |
| `test/alethea/clinical_record/rag/retrieval_test.exs` (F1) | Modify | 1 | 8 |
| `test/alethea/clinical_record/rag/indexer_session_transcript_test.exs`: `chunk_spans` unit | Create | 1 | 100 |
| same file: eligibility + `index_event` integration | Modify | 2 | 185 |
| `test/alethea_jobs/clinical_record_outbox_worker_test.exs`: AC4 + all-blank ack | Modify | 2 | 45 |
| **Test subtotal** | | | **393** |
| **Total** | | | **about 548** |

**PR split.** The candidate cut (PR1 = migration + schema + fixtures) is rejected: PR1 would be about 115 lines, and PR2 would be about 435 lines, which is still over budget. The recommended cut is:

- **PR1 (about 258): storage and pure chunking.** Migration, `Chunk`, fixtures, the F1 fix, and a public, uncalled `chunk_spans/1` with its full unit suite. It follows the #196 WU2 precedent of an uncalled, independently testable unit. It is green by itself and changes no live behavior, because eligibility still falls through to `:84`.
- **PR2 (about 290): wiring, stacked on PR1.** Eligibility and the fetch clause must land **together**: `{:index, :session_transcript}` without a fetch clause raises `FunctionClauseError`. This PR also adds the threading, R-X1, AC4, and the end-to-end tests.

---

## Testing Strategy (Strict TDD, RED first)

The transcript is built with `ClinicalRecord.create_session_transcript(professional, patient.id, %{spans: …, recorded_at: …})` (`clinical_record.ex:377`), and the test then builds the 5-key args by hand.

| Requirement | Test (layer) |
|---|---|
| AC1 eligibility | `eligibility("session_transcript_created") == {:index, :session_transcript}` (unit) |
| D-A / AC2 | 3 alternating spans → 3 pieces, `full_event: true`, speaker/start/end match, indices `0..2` (unit) |
| R-X2 | 1 span of about 700 tokens, `patient`, 10.0 to 340.0 → N ≥ 2 pieces, **all** `10.0`/`340.0`/`"patient"`, `full_event: false` (unit) |
| AD1 | span `start: 12, end: 48` → `is_float` and `== 12.0` (unit). Integer spans through `index_event/1` → `:ok`, row reads `12.0` (integration, **the real RED**) |
| D2 | blank + 2 non-blank spans → 2 pieces and 2 rows. All-blank → `[]`, `index_event == :ok`, 0 rows, embeddings mock `expect(:embed, 0, …)` |
| R-X1 | all-blank → `capture_log` contains the id and refutes the span text, `"patient"`/`"therapist"`, and `patient.id` |
| D5 | therapist-only transcript → rows with `speaker == "therapist"` |
| Columns / nil | therapist 12.5 to 48.75 round-trips. A `clinical_note` row has all three set to `nil` (integration) |
| AC3 / L5 | `encryption_version == 2`, decrypts under `load_clinical_record_dek`, embedding and model set, `source_occurred_at == recorded_at`, `target_behavior_id == nil` |
| No leak | raw `SELECT *::text` has no span text in any column. Job args keys == 5 identifiers |
| Idempotency | index twice → same count and same decrypted texts |
| AC4 | index, then `Retention.legally_delete_record(…, actor:, trigger: "manual")`, then `perform_job` with tombstone args → 0 rows (worker test) |
| AD6 | tampered `encrypted_spans` (valid ciphertext, bad sentinel) → `{:cancel, :malformed_transcript}` |
| Schema (PR1) | bad speaker, speaker on a `clinical_note` row, and `start > end` via `insert_all` each raise `Postgrex.Error` on the named constraint |

D4 waives the sentiment regression test. There is no RoBERTa or emotion diff.

## Threat Matrix

N/A: no routing, shell, subprocess, VCS/PR automation, executable-file classification, or process-integration boundary.

## Migration / Rollout

The migration is additive and nullable, with no backfill. Rollback is `mix ecto.rollback` for one step. Reverting PR2 alone returns events to the `{:unknown, _}` acknowledgement.

## Open Questions

- [ ] AD8's type-coupled constraint goes beyond the proposal's "3 nullable columns". A reviewer can veto it at the cost of the #328 DB guarantee and F1.
