# Tasks: Session transcript RAG ingestion and chunking (#320)

## Review Workload Forecast

| Field | Value |
|---|---|
| Estimated changed lines | PR1 ~258 / PR2 ~290 / Total ~548 |
| 400-line budget risk | PR1: Low · PR2: Low · Combined: High |
| Chained PRs recommended | Yes |
| Suggested split | PR1 (base: `feat/320-land-to-main`) → PR2 (base: PR1 branch) |
| Delivery strategy | ask-on-risk (resolved: feature-branch-chain, already approved) |
| Chain strategy | feature-branch-chain |
| Branches | tracker `feat/320-land-to-main` → `feat/320-transcript-rag-ingestion` → `feat/320-transcript-rag-ingestion-pr2` |

Decision needed before apply: No
Chained PRs recommended: Yes
Chain strategy: feature-branch-chain
400-line budget risk: High

### Suggested Work Units

| Unit | Goal | PR | Focused test command | Runtime harness | Rollback boundary |
|---|---|---|---|---|---|
| 1 | Storage + pure chunking: migration, `Chunk` schema, fixtures, F1 fix, uncalled `chunk_spans/1` + full unit suite | PR1 (base: tracker) | `mix test test/alethea/clinical_record/rag/chunk_test.exs test/alethea/clinical_record/rag/indexer_session_transcript_test.exs test/alethea/clinical_record/rag/retrieval_test.exs` | N/A — `chunk_spans/1` is uncalled; `:84` catch-all still owns the event | `mix ecto.rollback` one step + revert 7 files; nothing calls the new code |
| 2 | Wiring: eligibility+fetch (must land together), `pieces_for/2`, R-X1 warning, embed guard, attrs threading, AC4 proof | PR2 (base: PR1 branch) | `mix test test/alethea/clinical_record/rag/indexer_session_transcript_test.exs test/alethea_jobs/clinical_record_outbox_worker_test.exs` | Enqueue a real `session_transcript_created` outbox event and run the Oban worker end-to-end (integration tests exercise this path) | revert `indexer.ex` clauses + 2 test files; event falls back to `{:unknown, _}` ack, no job failures |

---

## Phase 0 — Branch setup

- [x] 0.1 From `main` (fa6e836): `git checkout -b feat/320-land-to-main`.
- [x] 0.2 Commit the untracked `openspec/sdd/transcript-rag-ingestion-320/` SDD artifacts (proposal.md, spec.md, design.md, tasks.md) on `feat/320-land-to-main` — keeps them out of PR1's diff against this base.
- [x] 0.3 From `feat/320-land-to-main`: `git checkout -b feat/320-transcript-rag-ingestion` (PR1 branch).

## PR1 — Storage and pure chunking (base: `feat/320-land-to-main`, branch `feat/320-transcript-rag-ingestion`)

### Phase 1 — Migration

- [x] 1.1 Run `mix ecto.gen.migration add_transcript_metadata_to_rag_chunks` (never hand-author).
- [x] 1.2 Write body per design "Migration": add `:speaker :string`, `:audio_start_seconds :float`, `:audio_end_seconds :float` to `clinical_record_rag_chunks`; create constraints `speaker_must_be_valid`, `transcript_metadata_consistent`, `audio_bounds_ordered` verbatim (AD8, D1, D3).
- [x] 1.3 `mix ecto.migrate` → `mix ecto.rollback` → `mix ecto.migrate` to prove reversibility.

### Phase 2 — `Chunk` schema (TDD)

- [x] 2.1 RED `test/alethea/clinical_record/rag/chunk_test.exs`: changeset casts `speaker`/`audio_start_seconds`/`audio_end_seconds`; `validate_inclusion(:speaker, SessionTranscriptContent.speakers())` rejects an invalid speaker (D1, D3).
- [x] 2.2 RED same file: `insert_all`-level constraint checks each raise `Postgrex.Error` on the named constraint — invalid speaker string, speaker set on a non-transcript `source_resource_type` row, `audio_start_seconds > audio_end_seconds` (AD8).
- [x] 2.3 GREEN `lib/alethea/clinical_record/rag/chunk.ex`: add 3 nullable fields (`chunk.ex:45-66`), 3 cast entries (`chunk.ex:75-105`), `validate_inclusion(:speaker, SessionTranscriptContent.speakers())`.

### Phase 3 — Fixtures + F1 retrieval fix

- [x] 3.1 Modify `test/support/fixtures/rag_fixtures.ex` `insert_chunk!/5`: add `:speaker`/`:audio_start_seconds`/`:audio_end_seconds` opts, default `nil`.
- [x] 3.2 Modify `test/alethea/clinical_record/rag/retrieval_test.exs:667-691` local `insert_chunk!/5` helper: when `resource_type == "session_transcript"`, populate speaker/start/end so the chunk seeded at `:457-464` satisfies `transcript_metadata_consistent` (F1, test-only, does not violate D-B).
- [x] 3.3 Run `retrieval_test.exs` to confirm the F1 fix is green against the new constraint.

### Phase 4 — `chunk_spans/1` (TDD, pure, uncalled)

- [x] 4.1 RED `test/alethea/clinical_record/rag/indexer_session_transcript_test.exs` (new): 3 alternating-speaker non-blank spans → 3 pieces, each `full_event: true` with matching speaker/start/end (D-A, AC2).
- [x] 4.2 RED same file: 1 oversized span (~700 tokens, `"patient"`, `10.0`-`340.0`) sub-splits into N≥2 pieces, ALL sharing speaker/start/end verbatim, `full_event: false` (R-X2).
- [x] 4.3 RED same file: integer `start: 12, end: 48` → piece's `audio_start_seconds`/`audio_end_seconds` are floats (`is_float`, `== 12.0`/`48.0`) (AD1).
- [x] 4.4 RED same file: `chunk_index` runs globally `0..n-1` across all spans in order (AD5).
- [x] 4.5 RED same file: blank/whitespace-only spans excluded before chunking; all-blank input → `[]` (D2, pure-function slice).
- [x] 4.6 GREEN `lib/alethea/clinical_record/rag/indexer.ex`: add public `@doc`'d `chunk_spans/1` + `span_chunk_piece` type exactly per design "Interfaces". Stays uncalled — `indexer.ex:84` catch-all still owns `session_transcript_created`.

### Phase 5 — PR1 verification

- [x] 5.1 `mix test test/alethea/clinical_record/rag/chunk_test.exs test/alethea/clinical_record/rag/indexer_session_transcript_test.exs test/alethea/clinical_record/rag/retrieval_test.exs`.
- [x] 5.2 `mix compile --warnings-as-errors --force`.
- [x] 5.3 `mix format` on ONLY the 7 touched files (migration, `chunk.ex`, `indexer.ex`, `chunk_test.exs`, `indexer_session_transcript_test.exs`, `retrieval_test.exs`, `rag_fixtures.ex`) — never repo-wide (Windows CRLF/HEEx risk).
- [x] 5.4 `git diff --stat feat/320-land-to-main` — confirm ~258 authored lines; if >400 flag `size:exception` to orchestrator, do not self-authorize. **Actual: 385+/15- = 400 changed lines (exactly at budget ceiling, not exceeding it — see risks).**
- [x] 5.5 Boundary check: diff touches ONLY the 7 PR1 files — no eligibility/fetch clause in `indexer.ex`, no `lib/alethea_web/**`, no `Retrieval`/`Citation`/`Consultation.Source`, no RoBERTa/emotion file (D-B, D4). Confirmed via `git status --short` and `git diff --cached indexer.ex`.

---

## PR2 — Wiring (base: `feat/320-transcript-rag-ingestion`, branch `feat/320-transcript-rag-ingestion-pr2`)

### Phase 6 — Branch setup

- [ ] 6.1 After PR1 verified, from `feat/320-transcript-rag-ingestion`: `git checkout -b feat/320-transcript-rag-ingestion-pr2`.

### Phase 7 — Eligibility + fetch clause (must land together, TDD)

- [ ] 7.1 RED `indexer_session_transcript_test.exs`: `eligibility("session_transcript_created") == {:index, :session_transcript}` (AC1).
- [ ] 7.2 RED same file: `fetch_and_decrypt(:session_transcript, ...)` for a persisted transcript (`encryption_version: 2`) returns spans in order, `occurred_at == recorded_at`, `target_behavior_id == nil` (L3, L4).
- [ ] 7.3 RED same file: tampered `encrypted_spans` (valid ciphertext, bad sentinel) → `{:cancel, :malformed_transcript}` (AD6).
- [ ] 7.4 GREEN `indexer.ex`: add `eligibility("session_transcript_created")` clause returning `{:index, :session_transcript}` before the `:84` catch-all, AND the `fetch_and_decrypt(:session_transcript, ...)` clause (`Repo.get` → `resolve_dek(2, ...)` → `PatientVault.decrypt` → `SessionTranscriptContent.parse/1`; parse failure → `{:cancel, :malformed_transcript}`). Land both in one commit — eligibility alone raises `FunctionClauseError`.

### Phase 8 — `pieces_for/2`, warning, embed guard, attrs (TDD)

- [ ] 8.1 RED same file: `index_event/1` for 1 blank + 2 non-blank spans writes exactly 2 chunks (D2).
- [ ] 8.2 RED same file: all-blank transcript → 0 chunks, `index_event/1` returns `:ok`, embed mock expects 0 calls (D2, AD7).
- [ ] 8.3 RED same file: all-blank indexing captures exactly one `Logger.warning` with the `resource_id`, refuting span text, `"patient"`/`"therapist"`, and `patient_id` (R-X1).
- [ ] 8.4 RED same file: therapist-only transcript → rows persist with `speaker == "therapist"` (D5).
- [ ] 8.5 RED same file: therapist turn 12.5s-48.75s round-trips (`speaker`, `audio_start_seconds`, `audio_end_seconds`); a `clinical_note` row has all three `nil`.
- [ ] 8.6 RED same file: `encryption_version == 2`, decrypts under the CR DEK, embedding/model set, `source_occurred_at == recorded_at`, `target_behavior_id == nil` (AC3, L5).
- [ ] 8.7 RED same file: integer span `start: 12, end: 48` through `index_event/1` persists as `12.0`/`48.0` — the real AD1 RED (`insert_all` bypasses the changeset).
- [ ] 8.8 RED same file: raw `SELECT *::text` on the row has no span text in any column; `oban_jobs.args` has exactly the 5 identifier keys (no-leak).
- [ ] 8.9 RED same file: indexing the same transcript twice converges to the same chunk count and texts (idempotency, L2).
- [ ] 8.10 GREEN `indexer.ex`: add `require Logger` (F2); `pieces_for/2` dispatch (`:session_transcript` → `chunk_spans(spans)`, others → `chunk/1`, byte-identical passthrough); `warn_if_empty/3` wired into `index_resource/5`; embed guard short-circuits `[]` to `{:ok, []}` (AD7); `encrypt_chunk_attrs/10` threads `speaker`/`audio_start_seconds`/`audio_end_seconds` via `Map.get(piece, ...)`.

### Phase 9 — AC4 legal-deletion purge

- [ ] 9.1 RED `test/alethea_jobs/clinical_record_outbox_worker_test.exs`: index a transcript, `Retention.legally_delete_record(..., actor:, trigger: "manual")`, `perform_job` with tombstone args → zero `clinical_record_rag_chunks` rows remain (AC4; production purge path at `indexer.ex:291-295` already exists — proof-only, F3).
- [ ] 9.2 Confirm 9.1 passes with no production code beyond Phase 8.

### Phase 10 — PR2 verification

- [ ] 10.1 `mix test test/alethea/clinical_record/rag/indexer_session_transcript_test.exs test/alethea_jobs/clinical_record_outbox_worker_test.exs`.
- [ ] 10.2 `mix test` (full suite).
- [ ] 10.3 `mix compile --warnings-as-errors --force`.
- [ ] 10.4 `mix format` on ONLY `indexer.ex` + the 2 touched test files.
- [ ] 10.5 `git diff --stat --cached feat/320-transcript-rag-ingestion` (staged, against PR1 base) — confirm ~290 authored lines; flag `size:exception` if over, do not self-authorize.
- [ ] 10.6 Boundary check: diff touches ONLY `indexer.ex` + the 2 test files — no `lib/alethea_web/**`, no `Retrieval`/`Citation`/`Consultation.Source`, no RoBERTa/emotion file (D-B, D4).
- [ ] 10.7 Base check: PR2's GitHub diff must NOT show PR1's files (`chunk.ex`, migration, fixtures, `retrieval_test.exs`) — retarget/rebase if it does.

## Threat Matrix

N/A — no routing, shell, subprocess, VCS/PR automation, executable-file classification, or process-integration boundary (per design).
