# Design — clinical-rag-projection

**Source issue:** alethea-org/Alethea#196 · **Phase:** sdd-design · **Store:** hybrid (Engram `sdd/clinical-rag-projection/design`)
**Builds on:** `proposal.md` (D1–D9, not reopened), `explore.md`.

## Technical Approach

Three seams, all patient-scoped: (1) a projection table + `RAG.Chunk` schema, (2) an ingest path where the existing no-op `ClinicalRecordOutboxWorker` becomes a thin dispatcher over `RAG.Indexer`, (3) a read path `RAG.Retrieval` feeding a new patient-scoped LiveView. The projection derives entirely from `ClinicalRecord`; nothing in the authoritative context changes.

### Codebase corrections to proposal wording (intent preserved, mechanism corrected)

| Proposal wording | Actual codebase | Resolution |
|---|---|---|
| "Cloak-encrypted chunk text" | Patient-level encryption is **`Alethea.Encryption.PatientVault.encrypt/2`** (AES-256-GCM, `encrypted_* :binary` + `encryption_version`). Cloak's global `Vault` only wraps **professional KEKs**. | Follow `ClinicalNote`/`ConsultationEvidence` exactly. D9's intent (patient-key encryption) is preserved; the mechanism name changes. |
| "reuse `TargetBehaviorLive.Review`'s citation/card components" | `Review` exposes **no function components** — cards are inline `render/1` markup + private helpers. | Reuse the **CSS class contract**, not components. See §7. |
| `search(patient_id, query, opts)` | Decryption needs the patient DEK, reachable only through the professional KEK ladder. | `search(professional, patient_id, query, opts)`. See §5. |
| `Embeddings.Fake` usable as-is | `Fake` returns **`[0.0]`, `dimensions/0 == 1`**. A 1-dim vector cannot enter `vector(1024)`, and pgvector cosine (`<=>`) on a **zero vector is NaN** — ranking tests would be meaningless. | `Fake` must emit deterministic, input-derived, non-zero 1024-dim vectors. Owned by **this** change (its stale `HF` moduledoc stays D1's). |

The KEK→DEK ladder is available to the worker: `ProfessionalKek.load_kek/1` decrypts from the global Vault server-side and already audits with reason `"session_auth_or_job_processing"`. No session is required for ingest.

## Architecture Decisions

### 1. Migration — `*_create_clinical_record_rag_chunks.exs`

**Independent of `20260526141108_add_sessions_and_embeddings.exs`.** That migration already ran; its vector content was only a **comment** (`CREATE EXTENSION` / `vector(384)` were never executed, no column exists). There is nothing to subsume or repair schema-wise. Per D7 the stale comment is annotated in place (comment-only edit — Ecto does not checksum migration bodies, and the `change/0` body is untouched) to point at 1024 and at this migration.

```elixir
execute("CREATE EXTENSION IF NOT EXISTS vector", "")   # no-op down: extension left in place (inert), per rollback plan
```

| Column | Type | Notes |
|---|---|---|
| `id` | `:binary_id` PK | |
| `patient_id` | FK → `patients`, `on_delete: :delete_all`, `null: false` | tenant boundary |
| `professional_id` | FK → `professionals`, `null: false` | provenance |
| `source_resource_type` | `:string`, `null: false` | `clinical_note` \| `consultation_evidence` \| `clinician_observation` \| `ai_proposal` \| `functional_analysis_draft` |
| `source_resource_id` | `:binary_id`, `null: false`, **no FK** | polymorphic across 5 tables — mirrors `ConsultationEvidence.source_id` (design A2 precedent) |
| `chunk_index` | `:integer`, `null: false` | 0-based |
| `encrypted_content` | `:binary`, `null: false` | PatientVault ciphertext |
| `encryption_version` | `:integer`, default `1` | |
| `embedding` | **`:vector, size: 1024`** | D7. Not encrypted (D9), local-only PII |
| `embedding_model` | `:string`, `null: false` | reindex provenance |
| `token_count` | `:integer` | |
| `full_event` | `:boolean`, `null: false`, default `true` | false ⇒ sub-chunk |
| `target_behavior_id` | `:binary_id`, nullable | D2 filter facet |
| `source_occurred_at` | `:utc_datetime_usec` | citation ordering |
| `timestamps(type: :utc_datetime)` | | `updated_at` kept (rows are replaced, not immutable) |

Indexes:
- `unique_index(:clinical_record_rag_chunks, [:source_resource_type, :source_resource_id, :chunk_index])` — **D3 idempotency key**.
- `index(..., [:patient_id])` — tenant scoping; lets the planner pick an exact scan for small patients.
- **HNSW**: `execute("CREATE INDEX ... USING hnsw (embedding vector_cosine_ops)", "DROP INDEX ...")`, defaults `m=16, ef_construction=64`.

**HNSW over IVFFlat (resolves the deferred "index type and parameters" risk).** IVFFlat requires a populated table to choose `lists`, and an IVFFlat index built on an **empty** table — exactly our case, since the migration precedes all data — produces degenerate clusters and must be rebuilt later. HNSW builds correctly on an empty table and degrades gracefully as rows arrive incrementally. Its costs (slower build, more memory) are irrelevant at this scale: chunk volume is per-patient clinical narrative — hundreds to low thousands of rows per patient, not web-scale. Accepted nuance: HNSW post-filters the `patient_id` predicate; at this cardinality the btree fallback covers the small-patient case.

### 2. Schema — `lib/alethea/clinical_record/rag/chunk.ex`

Follows `ConsultationEvidence` verbatim: `@derive {Inspect, except: [:content]}`, `field :content, :string, virtual: true, redact: true`, plaintext **never cast**. `field :embedding, Pgvector.Ecto.Vector` (dep `{:pgvector, "~> 0.3.0"}` present; `Alethea.PostgrexTypes` already registers the extension). `belongs_to :patient` / `:professional`. `changeset/2` casts persisted fields only and carries `unique_constraint/3` on the D3 key.

### 3. Indexer — `lib/alethea/clinical_record/rag/indexer.ex`

**Eligibility (extensible, no exhaustive list to restructure):**

```elixir
@spec eligibility(String.t()) :: {:index, String.t()} | {:ignore, atom()} | {:unknown, String.t()}
def eligibility("clinical_note_created"),            do: {:index, "clinical_note"}
def eligibility("consultation_evidence_created"),    do: {:index, "consultation_evidence"}
def eligibility("clinician_observation_created"),    do: {:index, "clinician_observation"}
def eligibility("clinician_observation_updated"),    do: {:index, "clinician_observation"}   # D4/D3 replace
def eligibility("ai_proposal_accepted"),             do: {:index, "ai_proposal"}             # D5
def eligibility("functional_analysis_draft_saved"),  do: {:index, "functional_analysis_draft"}
def eligibility("target_behavior_created"),          do: {:ignore, :structural_metadata}     # D2, explicit
def eligibility("ai_proposal_edited"),               do: {:ignore, :not_accepted}
def eligibility("ai_proposal_discarded"),            do: {:ignore, :not_accepted}
def eligibility(event) when is_binary(event),        do: {:unknown, event}
```

The trailing `{:unknown, _}` clause is the tombstone seam: #197 adds one `{:index, …}`/`{:tombstone, …}` clause above it with **zero restructuring**, and until then an unrecognised event is logged and acked rather than crashing or silently vanishing.

**`chunk/1` — hand-rolled, no new dependency.** A tokenizer dep is unjustified for a *soft* ~500-token boundary that the embedding model truncates anyway; a deterministic heuristic is also directly unit-testable.
- Token estimate: `words * 1.35` (Spanish subword inflation).
- Under budget ⇒ one chunk, `full_event: true` (ADR-003's "complete semanticable event").
- Over budget ⇒ paragraphs on `~r/\n{2,}/`; any still-oversized paragraph splits on sentences via `~r/(?<=[.!?…])\s+/u` (unicode-aware; Spanish `¿…?`/`¡…!` close with `?`/`!` so the lookbehind holds). Greedily pack sentences into ≤500-token windows, then prepend the trailing ~15% of the previous window as overlap. A single oversized sentence hard-splits on graphemes. All sub-chunks `full_event: false`.

**Embed:** one **batch** call `Alethea.AI.embeddings().embed(texts, [])` per resource (the behaviour guarantees same-order `[[float()]]`), not N single calls. A returned length ≠ `dimensions()` yields `{:cancel, {:embedding_dimension_mismatch, got, expected}}` — a model/config mismatch cannot be fixed by retrying, and `cancelled` keeps it visible in the existing Oban dashboard without burning backoff.

**`replace_chunks/2`:** one `Repo.transaction` — `delete_all` by `(source_resource_type, source_resource_id)`, then `insert_all` the fresh set. Delete-then-insert makes retries converge and gives D4/D5 replace-on-re-embed for free; the unique index aborts a concurrent double-run into `{:error, _}` → retry → converge.

### 4. Worker — `lib/alethea_jobs/clinical_record_outbox_worker.ex`

`max_attempts: 1` → `5`, Oban's **default exponential backoff** (no custom `backoff/1`).

```elixir
def perform(%Oban.Job{args: %{"event" => e, "resource_type" => t, "resource_id" => r,
                              "patient_id" => p, "professional_id" => pr}}),
  do: Indexer.index_event(%{event: e, resource_type: t, resource_id: r, patient_id: p, professional_id: pr})

def perform(%Oban.Job{args: args}), do: {:cancel, {:malformed_args, Map.keys(args)}}
```

| Outcome | Return | Reason |
|---|---|---|
| Indexed, or eligibility `{:ignore, _}` / `{:unknown, _}` | `:ok` | policy decision, not a failure |
| Embedding/HTTP/DB transient | `{:error, reason}` | retry with backoff |
| Malformed args, dimension mismatch, missing source row | `{:cancel, reason}` | unfixable by retry; stays visible |

**`test/alethea_jobs/clinical_record_outbox_worker_test.exs` must be REWRITTEN, not extended** (strict TDD — call this out in tasks). It currently locks in three things this change intentionally breaks: unconditional `:ok` (no-op contract), `max_attempts == 1`, and `FunctionClauseError` on short args (now `{:cancel, …}`, because crashing 5 times on unfixable input is wrong).

### 5. Retrieval — `lib/alethea/clinical_record/rag/retrieval.ex`

`search(%Professional{}, patient_id, query, opts)` — the professional is required for **both** halves of `with_patient`: `Accounts.get_patient_for_professional/2` (tenant authz) and the KEK→DEK ladder (decryption). A `patient_id`-only signature would either leak cross-tenant or force callers to hand around a raw DEK.

1. **Dense candidates** — embed the query, then patient-scoped ANN, `:candidate_limit` (default **50**):
   `where patient_id == ^patient_id`, `order_by fragment("embedding <=> ?", ^vec)`, selecting the distance as `dense_distance`.
2. **Decrypt** the ≤50 candidates with the DEK (`decrypt_or_placeholder` pattern from `ClinicalRecord`).
3. **Lexical rescoring — normalized token coverage** (chosen over the alternatives):

| Option | Verdict |
|---|---|
| `String.jaro_distance/2` | **Rejected.** Whole-string edit similarity; against a 500-token passage vs. a 5-word query it collapses toward noise, and it is O(n·m) per candidate. |
| Raw substring match | **Rejected.** Binary, misses Spanish morphology and accents. |
| **Token coverage (chosen)** | Fraction of query content-tokens present in the chunk, + a bonus for an exact phrase substring. Cheap, interpretable, and it models exactly the recall gap D9 accepts ("did the keyword appear"). |

Normalization: downcase → NFD via `:unicode.characters_to_nfd_binary/1` → strip combining marks → drop a small Spanish stopword list. Accent folding is mandatory here, not cosmetic.

4. **Merge:** `score = 0.7 * (1 - dense_distance) + 0.3 * lexical`; both terms in `[0,1]`. Weights are module attributes overridable via `opts`, so tuning never needs a migration. Sort desc, take `:limit` (default 10).

**Freshness.** Return `%{stale?: boolean, pending: n}` from one query over `oban_jobs`: `queue == "clinical_record_outbox"` and `state in ~w(available scheduled executing retryable)` and `args->>'patient_id' == ^patient_id`. Chosen over comparing a `last_indexed_at` against ClinicalRecord's last write: there is **no single per-patient last-write timestamp** (three tables plus the draft upsert), so that comparison costs four queries and still races. The outbox queue is the authoritative in-flight signal and is one query. Noted for verify: this is a non-indexed JSONB predicate — acceptable at demo scale, revisit if the queue grows.

**Decrypt-per-candidate latency (resolves the deferred risk):** bounded at `candidate_limit` = 50 decrypts of AES-256-GCM in-process, i.e. tens of microseconds each — sub-millisecond in aggregate and dominated by the embedding call. Decryption happens strictly **after** the LIMIT, never over the table. Measured in verify.

### 6. Rebuild entry point — Mix task

`mix alethea.rag.reindex --patient-id <uuid> [--confirm]`.

| Option | Verdict |
|---|---|
| **Mix task (chosen)** | Matches the repo's established manual-ops pattern — `alethea.demo.bootstrap`, `alethea.demo.process`, `alethea.demo.reset --confirm`, all operator-triggered and documented in `docs/main-demo-operator-guide.md`. Satisfies "manual, never cron" and is runbook-documentable. |
| Admin LiveView action | Rejected — adds an authz surface and UI to a slice already at 400-line budget risk. |
| IEx function | Rejected — undiscoverable, not runbook-documentable. |

Key design point: the task **re-enqueues outbox jobs**, it does not embed inline. Retry, backoff, and D3 idempotency all come from the existing worker path, so there is exactly one ingest code path.

### 7. LiveView — `lib/alethea_web/live/patient_live/clinical_search.ex`

Route inside the existing `live_session :require_authenticated_professional` (already supplies `mount_current_professional` + `require_authenticated_professional`):

```elixir
live("/patients/:patient_id/clinical-search", PatientLive.ClinicalSearch, :index)
```

Patient-scope authz is not re-implemented: it falls out of `Retrieval.search/4` → `get_patient_for_professional/2` → `{:error, :unauthorized}` (treating professional only, confirmed product decision 3).

**Presentation reuse.** `TargetBehaviorLive.Review` has no extractable components, so this slice reuses its **CSS class vocabulary** — `review-item`, `review-item__meta`, `review-item__text`, `review-item__source`, `badge`, `empty-state` — plus `core_components` (`<.header>`, `<.icon>`, `<.form>`, `<.input>`). Component extraction is deliberately **not** done here: it would churn `Review`'s tested `render/1` and inflate a diff already at budget risk.

- **Non-authoritative badge:** `<span class="badge badge--non-authoritative">` inside **every** result's `review-item__meta`, per result, non-dismissible (product decision 2) — never a one-time banner. The citation (source kind, `source_occurred_at`, link to the authoritative surface) renders in `review-item__source`.
- **Two empty states** (product decision 1), distinguished by a chunk-count returned in the same search envelope (one round trip): `:never_indexed` → "Aún no hay contenido indexado para este paciente" (+ the `pending` freshness hint); `:no_match` → "No se encontraron pasajes para esta búsqueda".
- Results use `stream/3` with `reset: true` on each query, per project LiveView conventions.

## Data Flow

```
ClinicalRecord write ──Ecto.Multi──> Outbox.event/2 ──> Oban job (5 identifier keys)
                                                          │
                              ClinicalRecordOutboxWorker (max_attempts: 5, exp backoff)
                                                          │
                                                    RAG.Indexer
             eligibility ─> KEK→DEK ─> load+decrypt source ─> chunk/1 ─> embed(batch)
                                                          │
                                    replace_chunks/2  [delete-by-resource + insert_all]
                                                          ▼
                                          clinical_record_rag_chunks (HNSW + unique idx)
                                                          │
  LiveView ──> Retrieval.search/4 ──> dense ANN (≤50) ──> decrypt ──> lexical rescore ──> merge
                                                          │
                             results + freshness + indexed? ──> badge + citation per card
```

## File Changes

| File | Action | Description |
|---|---|---|
| `priv/repo/migrations/*_create_clinical_record_rag_chunks.exs` | Create | extension, table, unique index, HNSW index |
| `priv/repo/migrations/20260526141108_add_sessions_and_embeddings.exs` | Modify | comment-only D7 annotation (384 → 1024, superseded) |
| `lib/alethea/clinical_record/rag/chunk.ex` | Create | schema, PatientVault pattern, `Pgvector.Ecto.Vector` |
| `lib/alethea/clinical_record/rag/indexer.ex` | Create | eligibility, chunking, embed, transactional replace |
| `lib/alethea/clinical_record/rag/retrieval.ex` | Create | dense + lexical + merge + freshness |
| `lib/alethea_jobs/clinical_record_outbox_worker.ex` | Modify | no-op → dispatcher, `max_attempts` 1 → 5 |
| `lib/alethea/ai/embeddings/fake.ex` | Modify | deterministic non-zero 1024-dim vectors |
| `lib/mix/tasks/alethea.rag.reindex.ex` | Create | manual re-enqueue |
| `lib/alethea_web/live/patient_live/clinical_search.ex` | Create | patient-scoped retrieval view |
| `lib/alethea_web/router.ex` | Modify | one `live/3` entry |
| `test/alethea_jobs/clinical_record_outbox_worker_test.exs` | **Rewrite** | locks the no-op + `max_attempts: 1` + `FunctionClauseError` contract |
| `docs/main-demo-operator-guide.md` | Modify | document `mix alethea.rag.reindex` |

## Testing Strategy (Strict TDD — RED first)

| Layer | What | Approach |
|---|---|---|
| Unit (pure, no DB) | `eligibility/1` per event incl. `{:ignore, :structural_metadata}` for D2, `{:unknown, _}` fallback; `chunk/1` under/over budget, paragraph vs sentence split, ~15% overlap, oversized single sentence; lexical normalization (accents, stopwords), score merge | plain ExUnit, `async: true` |
| Unit (DB, sandbox) | `Chunk` changeset; unique-index violation on the D3 key; `replace_chunks/2` converges on re-run | `DataCase`, `Fake` embeddings |
| Integration (Oban + Ecto sandbox) | Worker returns `:ok`/`{:error,_}`/`{:cancel,_}` per class; `max_attempts == 5`; a real event end-to-end produces retrievable chunks; **re-running the same job leaves exactly one chunk set** | `Oban` `testing: :manual` (already configured), `perform_job/2` |
| Integration (retrieval) | Patient scoping — a second patient's chunk is **never** returned; ranking with distinct `Fake` vectors; both empty-state variants; freshness `stale?` with a pending job | `DataCase` + real pgvector |
| Error injection | Transient embed failure → `{:error, _}` → retry; dimension mismatch → `{:cancel, _}` | `Mox.defmock` for `Alethea.AI.Embeddings` in `test_helper.exs` (established pattern) |
| LiveView | Badge present on every result; citation rendered; unauthorized professional blocked; stream reset per query | `LiveViewTest` |

`Fake` covers deterministic happy paths; **Mox covers failure injection** — `Fake` cannot express `{:error, _}`.

## Threat Matrix

**N/A** — this change introduces no shell command, subprocess, VCS/PR automation, executable-file classification, or process integration. The new Mix task runs in-process (`Repo` + `Oban.insert`) and spawns nothing; the new `live/3` route is request routing inside an existing authenticated `live_session`, not the dispatch/argument-composition boundary this matrix governs. The real security boundary here — cross-patient isolation and encryption-at-rest — is covered by the patient-scoping and PatientVault tests above, not by this matrix.

## Migration / Rollout

Forward: run the migration, merge, then re-enqueue history with `mix alethea.rag.reindex`. Rollback: revert + migration `down` (drops the table and HNSW index; the `vector` extension is intentionally left in place and is inert). No authoritative data is touched; the index is fully reconstructible.

**Merge-order constraint (D1):** operationally verifiable only after the `Alethea.AI.Embeddings.Ollama` prerequisite change lands (adapter + `:ai_embeddings` dev/runtime config + BGE-M3 in the runbook). Developable and fully testable against `Fake`/Mox in parallel.

## Open Questions

- [ ] **Slice decision required before apply.** Cached strategy is `single-pr`; forecast is High risk against the 400-line budget. Recommend PR1 = migration + schema + indexer + worker + `Fake` fix, PR2 = retrieval + LiveView + Mix task + docs. `sdd-tasks` must emit the guard forecast; the orchestrator must resolve chained-PR vs. `size:exception`.
- [ ] **ADR-003 amendment (D9).** This design confirms dense-first + in-application lexical rescoring and no `tsvector` anywhere, which narrows ADR-003's "pgvector + Postgres FTS" wording. Non-blocking for implementation; the ADR text should be amended to match.
