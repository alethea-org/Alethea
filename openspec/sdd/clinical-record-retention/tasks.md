# Tasks: clinical-record-retention (#197)

## Review Workload Forecast

| Field | Value |
|-------|-------|
| Estimated changed lines | 1350–1800 (design's own estimate) |
| Session review budget | 800 (cached, not repo default 400) |
| 400-line budget risk | High |
| Fits single-pr (800 budget)? | No — 1.7–2.25x over |
| Chained PRs recommended | Yes |
| Suggested split | PR A → PR B → PR C → PR D (slices below) |
| Delivery strategy (cached) | single-pr |
| Chain strategy | pending — conflicts with cached single-pr |

Decision needed before apply: Yes
Chained PRs recommended: Yes
Chain strategy: pending
400-line budget risk: High

**Conflict**: cached `delivery_strategy=single-pr` requires `size:exception` before apply, but estimated total (1350–1800) exceeds even the 800-line session budget by 1.7–2.25x. Orchestrator must either get maintainer `size:exception` approval for the full total, or switch to chained delivery (stacked-to-main or feature-branch-chain) before `sdd-apply` starts Slice A.

### Suggested Work Units

| Unit | Goal | Likely PR | Focused test command | Runtime harness | Rollback boundary |
|---|---|---|---|---|---|
| A | Lifecycle+Tombstone+hold+audit vocab+D4 gate | PR A | `mix test test/alethea/clinical_record/lifecycle_test.exs test/alethea/clinical_record/tombstone_test.exs test/alethea/clinical_record_test.exs` | `mix ecto.migrate` then manual write to a tombstoned fixture row | 3 migrations + 2 new modules, revertible via `mix ecto.rollback` |
| B | CR-scoped key + dual-read keyring | PR B | `mix test test/alethea/accounts_test.exs test/alethea/clinical_record_test.exs test/alethea/clinical_record/rag/indexer_test.exs test/alethea/clinical_record/rag/retrieval_test.exs` | Insert v1 fixture row, verify same `review_timeline/3` call decrypts v1+v2 | 2 migrations + key functions, additive only (no v1 row touched) |
| C | Retention + Sweep (inert) + purge wiring | PR C | `mix test test/alethea/clinical_record/retention_test.exs test/alethea_jobs/retention_sweep_worker_test.exs` | Oban testing mode: `perform_job/2` dry-run + `:retention_sweep_enabled=false` assertions | New module+worker, ships inert (2 guards); revert = delete files, drop crontab entry |
| D | LiveView tombstone affordance | PR D | `mix test test/alethea_web/live/clinical_review_prototype_live_test.exs` | `Phoenix.LiveViewTest` render of a timeline with a tombstoned entry | Template-only change, isolated to one LiveView module |

## Phase 1 — Slice A: Lifecycle, Tombstone, Hold, D4 Gate

- [x] 1.1 `mix ecto.gen.migration create_clinical_record_lifecycles` — table + `unique_index([:patient_id])` per design (a).
- [x] 1.2 `mix ecto.gen.migration create_clinical_record_tombstones` — table + 3 indexes per design (b).
- [x] 1.3 `mix ecto.gen.migration add_retention_indexes` — 6 single-column indexes per design (e). `mix ecto.migrate`.
- [x] 1.4 RED: `test/alethea/clinical_record/lifecycle_test.exs` — `apply_hold/2`, `release_hold/2`, `held?/1`, `set_retention_minimum/3`, `effective_retention_days/1` (max semantics, `nil` override → baseline).
- [x] 1.5 GREEN: create `lib/alethea/clinical_record/lifecycle.ex` implementing the 5 specs above; lazy row creation on first hold/override.
- [x] 1.6 RED: `test/alethea/clinical_record/tombstone_test.exs` — `for_resource/2` lookup, insert content-free, unique on `{resource_type, resource_id}`.
- [x] 1.7 GREEN: create `lib/alethea/clinical_record/tombstone.ex`.
- [x] 1.8 GREEN: `lib/alethea/clinical_record/audit.ex` — add `legal_hold_applied`, `legal_hold_released`, `clinical_record_legally_deleted`, `clinical_record_key_destroyed` to `@actions`; run existing `audit_test.exs`.
- [x] 1.9 RED (D4, spec scenarios "Write denied"/"Sibling readable"): extend `test/alethea/clinical_record_test.exs` — write to tombstoned resource → `{:error, :legally_deleted}` + 1 content-free `clinical_record_access_denied` row; sibling read unaffected.
- [x] 1.10 GREEN: `lib/alethea/clinical_record.ex` — widen `deny_access/2`→`/3`, add the `nil → Tombstone.for_resource` gate at the 3 existing `nil` branches (`:247`, `:358`, `:579`).
- [x] 1.11 RED (BR2 hold scenarios): extend `lifecycle_test.exs`/`clinical_record_test.exs` — active hold pauses manual deletion attempt (stub), audited as paused; lift re-exposes eligibility with no clock change.
- [x] 1.12 REFACTOR: confirm `mix precommit` green; no behavior beyond 1.1–1.11.

## Phase 2 — Slice B: CR-Scoped Key + Dual-Read (depends on Phase 1 migrations tooling only)

- [x] 2.1 `mix ecto.gen.migration add_unique_index_encryption_keys_patient_type` — partial unique index per design (c).
- [x] 2.2 `mix ecto.gen.migration add_encryption_version_to_clinical_record_tables` — add column to `clinician_observations`, `ai_proposals`, `functional_analysis_drafts` per design (d). `mix ecto.migrate`.
- [x] 2.3 GREEN: `lib/alethea/accounts/encryption_key.ex` — widen `validate_inclusion(:type, [...])` to include `"patient_clinical_record"`.
- [x] 2.4 RED: extend `test/alethea/accounts_test.exs` — `load_clinical_record_dek/2`, `ensure_clinical_record_dek/2` (lazy, race-safe via `on_conflict: :nothing` + re-read), `destroy_clinical_record_dek/1` returns `:destroyed`/`:absent`.
- [x] 2.5 **RED — mandatory D1/BR3 boundary test**: same file — terminal `destroy_clinical_record_dek/1` deletes only the `"patient_clinical_record"` row; the `"patient"` row survives; `Alethea.Clinical.patient_dek/1` still decrypts journaling afterward.
- [x] 2.6 GREEN: `lib/alethea/accounts.ex` — implement the 3 functions from 2.4/2.5; verify `type == "patient"` literals at `:121`, `:209`, `:221` remain untouched (design's D1/BR3 boundary table).
- [x] 2.7 RED: extend `test/alethea/clinical_record_test.exs` — a v1 fixture row and a new v2 write on the same patient both decrypt in one `review_timeline/3` call.
- [x] 2.8 GREEN: `lib/alethea/clinical_record.ex` — `keyring` type, `dek_for/2` by `encryption_version`, `with_patient/3` passes keyring not single DEK; writes stamp `encryption_version: 2`.
- [x] 2.9 RED/GREEN: extend `test/alethea/clinical_record/rag/indexer_test.exs` and `retrieval_test.exs` — dual-read by chunk `encryption_version`; wire `lib/alethea/clinical_record/rag/indexer.ex` (`index_resource/5`) and `rag/retrieval.ex` accordingly.
- [x] 2.10 REFACTOR: scoped `mix compile --warnings-as-errors` + `mix format --check-formatted` + `mix test` (bare `mix precommit` avoided per Slice A's documented CRLF-reformat incident); confirm no v1 row re-encryption path exists anywhere (AD1).

## Phase 3 — Slice C: Retention, Sweep (inert), Purge (depends on Phase 1 + Phase 2)

- [x] 3.1 RED: `test/alethea/clinical_record/retention_test.exs` — `eligible_records/2` per table: own-clock independence (spec "no cross-restart"), stricter-minimum wins (AD3 `GREATEST`), `left_join` correctness for a patient with no lifecycle row, `select:` loads identifiers only (no ciphertext column).
- [x] 3.2 GREEN: create `lib/alethea/clinical_record/retention.ex` — `eligible_records/2` for all 6 tables per design's query shape.
- [x] 3.3 RED: same file — `legally_delete_record/2` primitive: hard-delete + tombstone + audit (attributed by `trigger`) + `Outbox.tombstone_event/4` enqueued + zero-remaining crypto-erasure fires exactly once, never with an active sibling.
- [x] 3.4 GREEN: implement `legally_delete_record/2` as one `Ecto.Multi` (`:record`, `:tombstone`, `:audit`, `:rag_purge`, `:crypto_erasure`) per design's Data Flow.
- [x] 3.5 RED (BR11): same file — `legally_delete_patient_record/3` iterates via `Enum.reduce_while` (not one transaction, AD4), authorizes once, checks hold once, partial result on mid-iteration failure is reportable not rolled back.
- [x] 3.6 GREEN: implement `legally_delete_patient_record/3`.
- [x] 3.7 GREEN: `lib/alethea/clinical_record/outbox.ex` — add `tombstone_event/4` (same `@allowed_args` allowlist).
- [x] 3.8 RED: extend `test/alethea/clinical_record/rag/indexer_test.exs` (tombstone seam) — `eligibility("clinical_record_legally_deleted") == {:tombstone, :legal_deletion}`; `index_event/1` purge branch calls `replace_chunks(ref, [])` and never reaches KEK/DEK load or decrypt; no-op success when zero chunks existed.
- [x] 3.9 GREEN: `lib/alethea/clinical_record/rag/indexer.ex` — add the eligibility clause and `{:tombstone, _}` branch before `{:index, _}`.
- [x] 3.10 RED: `test/alethea_jobs/retention_sweep_worker_test.exs` — inert when `:retention_sweep_enabled=false`; dry-run default reports counts, writes nothing; `max_attempts: 1`.
- [x] 3.11 GREEN: create `lib/alethea_jobs/retention_sweep_worker.ex` per design's `perform/1` cond.
- [x] 3.12 GREEN: `config/config.exs` — `clinical_record_retention: 1` queue, crontab entry, `:retention_sweep_enabled` (false), `:retention_baseline_days` (3650).
- [x] 3.13 REFACTOR: scoped `mix compile --warnings-as-errors` + `mix format --check-formatted` + `mix test` (bare `mix precommit` avoided per Slice A's documented CRLF-reformat incident); confirm sweep concurrency 1 and dry-run-true are both satisfied simultaneously (double gate — proven together in `retention_sweep_worker_test.exs`'s "both guards down" describe block).

## Phase 4 — Slice D: Tombstone Affordance in LiveView (depends on Phase 1–3)

- [x] 4.1 RED: extend `test/alethea_web/live/target_behavior_live/review_test.exs` (deviation: `clinical_review_prototype_live_test.exs` is a data-free Wayfinder #186 prototype that never calls `review_timeline/3` — see Deviations) — timeline render includes a tombstoned entry as "legally deleted on {date}" (Spanish UI copy: "Eliminado legalmente el {date}"), no original content, ordered by `{occurred_at, kind_rank, id}`.
- [x] 4.2 GREEN: `lib/alethea/clinical_record.ex` — `review_timeline/3` merges `Tombstone` rows via `target_behavior_id`, new `kind_rank/1` clause for `:legally_deleted`.
- [x] 4.3 GREEN: `lib/alethea_web/live/target_behavior_live/review.ex` (deviation, see 4.1) — render tombstone entries (content-free, date-stamped) using existing `<.icon>`/core components (`hero-lock-closed`, already in the icon set).
- [x] 4.4 RED/GREEN: same test file — `get_functional_analysis_draft/3` returns `{:ok, {:legally_deleted, deleted_at}}` when tombstoned; LiveView renders it distinctly from `nil` via new `Tombstone.for_target_behavior/2` + `@draft_tombstoned_at` assign.
- [x] 4.5 REFACTOR: scoped `mix compile --warnings-as-errors` + `mix format --check-formatted` + `mix test` (bare `mix precommit` avoided per Slice A's documented CRLF-reformat incident — recurred again this batch, fixed); confirmed no dead `nil`-tombstone branch remains (mount's 4-clause case and `get_functional_analysis_draft/3`'s nil-branch tombstone check are both exhaustive and ordered correctly).

## Key Learnings

1. Design already fixed the per-slice line estimates (350–450 / 450–600 / 400–500 / 150–250), so tasks.md only had to map them onto concrete RED/GREEN pairs, not re-derive scope.
2. The mandatory D1/BR3 boundary test (task 2.5) had to be pinned to the exact same test file as the CR-key functions it guards, since it is the single enforcement point named in the design.
3. Slice C's sweep worker needs two independent inert guards tested together (task 3.13), not just individually, because the design's rollback plan relies on both holding simultaneously.
4. Slice D has no CLI task — the earlier `mix alethea.clinical_record.rekey` idea was dropped from scope per the closed AD1 open question, so `alethea.rag.reindex` is referenced only as a style precedent for Slice C's worker conventions, not as a new task.
5. The 800-line session-cached budget (not the repo-wide 400) still cannot absorb the design's own 1350–1800 estimate under `single-pr`, so the forecast surfaces a real conflict rather than resolving it here.
