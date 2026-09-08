# Proposal — clinical-record-retention

**Source issue:** alethea-org/Alethea#197 — "Deliver ClinicalRecord retention and legal-deletion behavior"
**Artifact store:** hybrid (mirrored to Engram `sdd/clinical-record-retention/proposal`)
**Strict TDD:** active — test runner `mix test`.
**Depends on exploration:** Engram `sdd/clinical-record-retention/explore`.
**Fixed inputs (not re-decided here):** ADR-003 (single immediate-delete RAG purge mechanism, no soft-delete, no RAG-side sweep) and every business rule below.
**Revision:** amended after the product owner's answers to the first question round. Four assumptions confirmed; the clock-semantics assumption was **corrected**, which reworked the deletion granularity, D1, D2, D4, the approach, and the risks.

## Intent

**Problem.** `Alethea.ClinicalRecord` accumulates clinical content forever. There is no retention window, no deletion path, no legal-hold concept, and no code anywhere that destroys a key — CLAUDE.md security mandate #4 ("cryptographic deletion... destroying keys in the Vault") is aspirational. `Patient.status` accepts `"deleted"` but no function ever sets it; only `archive_patient/1` exists. A patient who requests erasure, or a record past its retention window, has no path today.

**Why now.** ADR-003 fixed the RAG purge *mechanism* and explicitly deferred the retention *window* to this issue. #196 shipped the projection with "no tombstone producer" as a documented known limitation, so retracted or expired material stays indexed and retrievable. The migrations for `clinical_notes` and `target_behaviors` already carry forward-looking comments about "future key-destruction erasure", and the indexer's `eligibility/1` catch-all is a documented seam waiting for this change.

**Success.** Each clinical record ages out on its own ten-year clock, a legal hold on the patient pauses every one of their records, an expired record is replaced by an explicit tombstone and its RAG projection is gone, a content-free audit trail proves each individual deletion, and the patient's clinical content becomes cryptographically unrecoverable once none of it remains.

## Business rules (settled by the product owner — not re-litigated)

| # | Rule |
|---|---|
| **BR1** | Retention baseline is **ten years from the last clinical action**, honoring stricter applicable minimums. Settled team business decision. No statute citation exists in this repository and none is required; do not invent one. |
| **BR2** | Legal hold is **per-patient**: one patient-scoped state that pauses deletion for **all** of that patient's clinical records at once, regardless of each record's individual clock. |
| **BR3** | Legal deletion destroys **only** content in the six `ClinicalRecord` tables (`target_behaviors`, `clinical_notes`, `consultation_evidences`, `clinician_observations`, `ai_proposals`, `functional_analysis_drafts`) plus its RAG projection. The `Patient`/account survives for other purposes (Telegram channel, billing). |
| **BR4** | Two triggers, **one gate and one mechanism**: an automatic periodic Oban cron sweep and a manual professional-initiated deletion. |
| **BR5** | **Per-record clock.** Every individual row in the six tables carries its **own independent** ten-year clock, computed from **its own** last-clinical-action timestamp. There is **no patient-wide `MAX`**. An action on one record never restarts another record's clock — a new `clinician_observation` on old material restarts only that observation's own clock, not the parent record's and not the patient's. |
| **BR6** | **Per-record execution.** Deletion is evaluated and executed **per record**, never as one patient-wide operation. A **mixed state is expected and legal**: at the same moment a patient may have some records already legally deleted (tombstoned) while others remain active and fully readable. |
| **BR7** | The stricter applicable minimum is an **optional per-patient override field**, defaulting to the global ten-year baseline. The stricter of the two always wins. |
| **BR8** | Manual deletion is authorized by the **treating professional**, through the same authorization ladder as every other `ClinicalRecord` entry point. No admin role is introduced. |
| **BR9** | Manual deletion executes **immediately on explicit confirmation**. No cool-off or grace window, despite irreversibility. |
| **BR10** | After deletion the clinician sees an explicit, content-free **"legally deleted on {date}" tombstone** in place of the record. Silent disappearance is forbidden — a deletion must be explainable. |
| **BR11** | Manual deletion (BR8/BR9) supports **both** a single targeted record **and** the patient's entire clinical record at once. The deletion primitive stays per-record (BR6); a whole-patient manual deletion is a bounded iteration over that same primitive, behind the same per-patient hold gate (BR2) — an authorization/affordance choice, not a second mechanism. |
| **BR12** | The deferred crypto-erasure window (D1) is an **accepted risk**: a deleted record's ciphertext may remain backup-decryptable until the patient's last clinical-record row expires. This is bounded operationally by backup retention/rotation policy, not by additional code. Per-record keys were explicitly considered and rejected (see D1) as disproportionate to close this window. |

> **Two independent axes — do not conflate them.** *Hold granularity* is **per-patient** (BR2): one hold freezes every record that patient has. *Deletion-execution granularity* is **per-record** (BR6): each record is evaluated and deleted against its own clock. A patient-level hold and record-level deletion are fully compatible — the gate is checked once per patient, the mechanism runs once per record. `sdd-design` must not "harmonize" these into a single granularity.

## Scope

### In scope

- **Patient-scoped clinical-record lifecycle state**, *separate from* `patients.status`: the legal-hold flag (+ who/when) and the optional stricter-minimum override (BR7). `patients.status = "deleted"` MUST stay unused — `Accounts.get_patient_for_professional/2` and `list_patients/1` already filter it out, which would break BR3.
- **Per-record retention eligibility** (BR5): normalize each of the six tables' own timestamp shapes into a per-row "last clinical action" (create-only → `inserted_at`; occurred-at-bearing → `occurred_at`; mutable-in-place → `updated_at`). No patient-wide aggregate and **no denormalized patient-scoped column** — the correction removes that need entirely.
- **Configurable global baseline** (default ten years) plus the per-patient stricter override; stricter always wins.
- **Legal hold**: apply/lift API, checked once per patient by both triggers before any of that patient's records are touched.
- **Per-record erasure operation**: hard-delete one row, write its tombstone, write its audit row, purge that resource's RAG chunks — one transactional unit per record (**D2**).
- **Terminal crypto-erasure**: destroy the clinical-record-scoped encryption key when, and only when, the patient's remaining clinical-record content across all six tables reaches zero (**D1**).
- **Per-record tombstone representation** surviving the deleted row, rendering BR10's "legally deleted on {date}" and content-free by construction (**D5**).
- **Per-record access behavior**: a read of a deleted record returns its tombstone; a write targeting one is denied immediately through the existing `deny_access/2` seam, reusing `clinical_record_access_denied`. Sibling records of the same patient stay fully readable (**D4**).
- **RAG purge**: the anticipated `{:tombstone, _}` clause in `Indexer.eligibility/1` plus a purge branch short-circuiting *before* `fetch_and_decrypt/3`, calling `replace_chunks({resource_type, resource_id}, [])` per ADR-003. This seam is already keyed per resource, so per-record purge fits it natively.
- **Audit vocabulary**: new closed-vocabulary `@actions` entries in `ClinicalRecord.Audit` for hold applied/lifted and legal deletion. **No `@resource_types` or schema change is needed for per-record attribution** — the allowlist already contains all six per-record types and `resource_id` is a plain `:binary_id` field, not an FK, so one audit row per deleted record is natively supported and survives erasure.
- **Retention sweep worker** following `AletheaJobs.DailySchedulerWorker` + `Oban.Plugins.Cron`, iterating eligible **records**, plus a manual entry point routed through the same gate and mechanism.

### Out of scope (explicit non-goals)

- **Per-record legal-hold granularity** — BR2 fixes hold at the patient level. Per-record *deletion* (BR6) does not imply per-record *hold*.
- **Patient / account row deletion or anonymization.** No `Patient` row is deleted, no `patients.status` transition to `"deleted"`, no Telegram teardown, no billing effect.
- **`Alethea.Clinical` journaling content** (Telegram messages, summaries, trends) — a separate concern; D1 exists precisely to keep it out of this blast radius.
- **Re-litigating ADR-003's RAG purge mechanism.** Immediate delete, no soft-delete, no RAG-side periodic sweep.
- **Sourcing a statutory citation** for the ten-year figure (BR1).
- **General key rotation/versioning** beyond erasure needs. `encryption_keys.version` stays as-is.
- **Restore / undelete / export-before-delete.** Erasure is irreversible by design.

## Capabilities

> This repository has no `openspec/specs/` source-of-truth tree; the delta lands at `openspec/sdd/clinical-record-retention/spec.md` per repo convention.

### New capabilities

- `clinical-record-retention`: per-record retention window and eligibility, per-patient legal hold, per-record legal deletion with tombstones, terminal crypto-erasure, post-deletion read/write behavior, RAG projection purge, and minimal audit-proof preservation.

### Modified capabilities

- `clinical-rag-projection`: adds the tombstone/purge event type that #196 explicitly deferred (`openspec/sdd/archive/2026-09-04-clinical-rag-projection/spec.md`). The only spec-level change to an existing capability.

## Approach

```
Trigger A: RetentionSweepWorker (Oban cron, daily)
   └─ for each RECORD across the 6 tables:
        eligible? record.own_last_clinical_action
                    + max(global_baseline, patient.stricter_minimum) <= now
Trigger B: manual legal deletion (treating professional, explicit confirm, immediate)
   │
   └────► LEGAL HOLD GATE  — per PATIENT (BR2), checked once
             │  held ──► pause every record of that patient, no state change, audit
             │ not held
             ▼
      legally_delete_record({resource_type, resource_id})   [one transaction, ONE record]
             ├─ hard-delete that single row
             ├─ insert content-free tombstone row  (resource_type, resource_id, deleted_at)   (D5)
             ├─ insert content-free Audit row      (existing per-record resource_type + id)
             ├─ enqueue RAG purge for that resource only                                       (D2)
             │     └─ Indexer.eligibility → {:tombstone, _}
             │          └─ replace_chunks({resource_type, resource_id}, [])   (no decryption)
             └─ if the patient now has ZERO rows across all 6 tables:
                   destroy the clinical-record encryption key row   (D1, terminal crypto-erasure)

Read  a deleted record ──► content-free tombstone: "legally deleted on {date}"   (BR10)
Write a deleted record ──► deny_access/2, immediate + audited                    (D4)
Sibling records of the same patient remain fully readable — mixed state is legal (BR6).
```

The sweep runs with **no professional session and therefore no KEK** — it can delete rows and destroy a key but can never decrypt anything. Preserve that property deliberately.

### Key decisions

| # | Decision | Rationale |
|---|---|---|
| **D1** | **One clinical-record-scoped encryption key per patient, destroyed only at zero remaining records.** Introduce a new `encryption_keys` row type (e.g. `"patient_clinical_record"`) wrapped under the same professional KEK, used by `ClinicalRecord` and the RAG chunks only. It is created lazily on the patient's first clinical write, **destroyed when the patient's last clinical-record row is legally deleted**, and recreated lazily if clinical content is ever written again. An individual record's deletion before that point is **hard-delete-only**; true cryptographic unrecoverability is deferred to the terminal step. | Two constraints collide. **BR3** forbids destroying the single shared patient DEK — `Alethea.Clinical.patient_dek/1` (`lib/alethea/clinical.ex:348`) decrypts Telegram messages/summaries/trends with the *same* key `ClinicalRecord`, `Rag.Indexer` and `Rag.Retrieval` use, so destroying it would crypto-erase the journaling side. **BR6** forbids destroying the clinical-record key on the first record's expiry, since that would render every still-active sibling record unreadable and break the required mixed state. Deferring destruction to zero-remaining satisfies both. **Rejected: per-record keys.** They would make backup-level erasure exact, but cost one `encryption_keys` row per clinical row (unbounded 1:1 growth), N key unwraps per list/index/retrieval read instead of one, a changed `PatientVault` contract and every caller, and multiply the already-High D1 backfill by the row count — disproportionate for a bounded backup-window guarantee. **Rejected: per-table keys.** Records within one table also age independently, so six keys still cannot express mixed state. **Accepted residual:** see the deferred-erasure risk. |
| **D2** | **Row deletion per record (immediate) and crypto-erasure once per patient (deferred) — both, but decoupled in time.** Each record's transaction hard-deletes its row, tombstones it, audits it and purges its RAG chunks. The key-destruction step is a conditional tail on the same transaction, firing only at zero remaining. | Row deletion alone is restorable from any backup, so it is not "cryptographic erasure"; key destruction alone leaves undecryptable garbage rows and a weaker legal story. Under BR6 they can no longer fire together for every record, so the mechanism separates *what happens per record* from *what happens once per patient*. This also matches the migrations' own "future key-destruction erasure" comment and ADR-003's anti-soft-delete stance. |
| **D3** | **Legal hold and the stricter-minimum override live on a patient-scoped clinical-record lifecycle representation, never on `patients.status`. The legally-deleted marker is *not* here — it is per-record (D5).** | `patients.status = "deleted"` is already filtered out by `Accounts.get_patient_for_professional/2`, `list_patients/1` and `list_critical_patients/1`; using it would hide the patient from every surface and violate BR3. Under BR6 a patient-scoped "legally deleted" flag is meaningless — deletion is no longer a patient-level state. |
| **D4** | **Per-record behavior at the authorization seam: read a deleted record → tombstone, write a deleted record → explicit audited denial.** The patient-level authorization ladder at `Accounts.get_patient_for_professional/2` is unchanged; the legally-deleted check moves down to the per-record read/write path. | BR10 requires the clinician to *see* an explanation, so a read must render the tombstone, not vanish or 404. A write must still be an explicit, audited, deterministic denial: letting `load_patient_dek/2` or a missing row fail produces an indistinguishable `{:error, :not_found}` that reads as a bug, not a policy decision. Patient-level denial is no longer correct — siblings must stay readable. |
| **D5** | **A dedicated per-record tombstone representation, not the audit row.** One content-free row per legally deleted record (`resource_type`, `resource_id`, `deleted_at`, patient scope), outliving the hard-deleted content row. | BR10's tombstone is a hot read path joined into ordinary record listings; the audit row is immutable legal proof. `audit_logs` is shared with `Accounts.AuditLog`, whose `details` map is unconstrained — building clinician-facing UI on a shared, mixed-writer table is fragile. Keeping them separate preserves "audit proves it happened" and "tombstone explains it to the clinician" as distinct concerns. Both are content-free and both survive erasure. |

## Affected areas

| Area | File | Impact |
|---|---|---|
| Domain seam | `lib/alethea/clinical_record.ex` | Modified — per-record lifecycle gate on read/write; new per-record `legally_delete_record/…` |
| Audit vocabulary | `lib/alethea/clinical_record/audit.ex` | Modified — new `@actions` only; `@resource_types` and `resource_id` already support per-record attribution |
| Tombstones | new schema + migration | New — per-record content-free tombstone (D5) |
| Key model | `lib/alethea/accounts.ex`, `lib/alethea/accounts/encryption_key.ex` | Modified — CR-scoped key type (`validate_inclusion` allowlist), lazy creation, zero-remaining destroyer (D1) |
| Journaling boundary | `lib/alethea/clinical.ex` | Verify only — must keep using the original patient DEK |
| RAG purge | `lib/alethea/clinical_record/rag/indexer.ex` | Modified — tombstone eligibility clause + per-resource purge branch |
| Citations | `lib/alethea/clinical_record/source_ref.ex` | Verify/extend — `:unavailable` degradation exercised by per-record deletion, including a deleted parent |
| Sweep | `lib/alethea_jobs/retention_sweep_worker.ex`, `config/config.exs` | New — per-record worker + crontab entry |
| Migrations | `priv/repo/migrations/*` | New — patient lifecycle state (hold + stricter minimum), tombstone table, CR key type. **Dropped:** the denormalized last-clinical-action column is no longer needed |

## Risks

| Risk | Likelihood | Mitigation |
|---|---|---|
| **Deferred crypto-erasure window (from D1).** Between an individual record's deletion and the patient's last record expiring, that record's ciphertext stays decryptable in DB backups/WAL under the still-live clinical-record key. For a continuously active patient the window is effectively unbounded. | **High** | **Accepted by the product owner (BR12).** Inherent to mixed state: any key surviving for active siblings can also decrypt a deleted sibling's backup copy, so no key scheme short of rejected per-record keys closes it. Bound it operationally through backup retention/rotation (not code); documented as an explicit known limitation. The live DB and the RAG projection are clean immediately. |
| **D1 backfill** re-encrypts existing `ClinicalRecord` + RAG ciphertext under a new key and needs a professional KEK the migration process does not have. | **High** | Still the biggest `sdd-design` item, but easier now: D1's key lifecycle is already lazy (created on first write, destroyed at zero, recreated on next write), so a lazy on-next-access re-wrap is the natural fit rather than a plain migration. May justify its own PR slice. |
| **Irreversible erasure shipped behind an automatic cron.** A bug in per-record eligibility deletes real clinical records. | **High** | Blast radius per run is now smaller (individual records) but the sweep touches many more units. Ship the cron entry disabled/flagged; dry-run reporting eligible records first; rollback must never have to undo an erasure. |
| **400-line budget overrun** — migrations, key lifecycle, tombstones, per-record gate, worker, indexer, LiveView tombstone affordance, strict-TDD tests. | **High** | `sdd-tasks` must forecast and recommend chained slices (PR1 lifecycle state + hold + per-record tombstone + read/write gate, PR2 per-record erasure + key lifecycle, PR3 sweep + RAG purge). Cached strategy is `single-pr` — needs an orchestrator decision before apply. |
| **Orphaned references under strict per-record clocks (new, from BR5).** A parent `target_behavior` can expire and be deleted while a child `clinician_observation` on it survives with a fresher clock, leaving a dangling parent reference. | Medium | Explicit consequence of BR5, not a defect. `SourceRef` already degrades to `:unavailable`; require scenario coverage for a surviving child whose parent was legally deleted, and render the parent's tombstone rather than raising. |
| **Cited-source breakage** — a legally deleted note cited by a `ConsultationEvidence` excerpt. | Medium | `SourceRef`'s `:unavailable` path already exists; require explicit legal-deletion scenario coverage. |
| **Sweep-scale eligibility query** across six tables with three timestamp shapes. | Low | **Downgraded by BR5.** Each row's own timestamp is already on the row, so this is six indexed per-table range scans — no patient-wide `MAX`, no denormalized column, no per-write `Ecto.Multi` change. |
| **Ten-year clock arithmetic** (timezones, UTC boundaries, leap years). | Low | Compute in UTC against `utc_datetime` columns; boundary tests at exactly the threshold. |

## Rollback plan

Everything *before* an erasure runs is a normal revert: revert the PR and roll back the migrations (lifecycle columns, tombstone table, CR key type). **The erasure itself is not reversible** — that is the point. Therefore the sweep's crontab entry ships **disabled by default** and is enabled only after verification, so rollback never has to undo a destroyed key or a hard-deleted record. The manual path requires explicit confirmation (BR9). The RAG projection is non-authoritative and fully reconstructible for any *non-deleted* record via the existing on-demand rebuild.

## Dependencies

- **Blocking:** none. #196 (RAG projection) is merged; its per-resource tombstone seam is in place.
- **Constrained by:** ADR-003 (purge mechanism), CLAUDE.md security mandates #1 and #4.
- **May require:** an ADR amendment or new ADR recording D1's key scoping and its deferred-erasure tradeoff.

## Success criteria

- [ ] Eligibility is computed **per record** from that record's own last-clinical-action timestamp at the ten-year baseline — never a patient-wide `MAX`.
- [ ] An action on one record does not restart any other record's clock, including a child observation added to old material.
- [ ] A configured per-patient stricter minimum overrides the global baseline; the stricter value always wins.
- [ ] **Mixed state works:** a single patient simultaneously holds legally deleted (tombstoned) records and active, fully readable ones.
- [ ] An active per-patient legal hold pauses deletion for **every** one of that patient's records regardless of their individual clocks; lifting it re-exposes each record's own eligibility.
- [ ] Reading a legally deleted record returns a content-free "legally deleted on {date}" tombstone; writing to one is denied immediately with a content-free audit row; sibling records are unaffected.
- [ ] One content-free `Audit` row per deleted record, attributable via the existing `resource_type` + `resource_id` with no audit schema change, surviving erasure.
- [ ] Each deleted record is absent from the live database and no RAG chunk for it remains retrievable; a citation to erased material degrades to `:unavailable` rather than raising.
- [ ] The clinical-record encryption key is destroyed exactly when the patient's remaining clinical-record content reaches zero, and never while any record is still active.
- [ ] The patient's non-clinical existence (account, Telegram channel, `Alethea.Clinical` journaling) is unaffected, and the shared patient DEK is never destroyed by this change.
- [ ] `mix precommit` passes.

## Proposal question rounds — CLOSED

All questions from round 1 are settled as BR5–BR10. The single round-2 question (manual deletion granularity) is settled as BR11 — confirmed by the product owner: **both** single-record and whole-patient-at-once are supported, via bounded iteration over the same per-record primitive. The deferred crypto-erasure window (D1) is settled as an accepted risk, BR12. No open questions remain; ready for `sdd-spec` and `sdd-design`.
