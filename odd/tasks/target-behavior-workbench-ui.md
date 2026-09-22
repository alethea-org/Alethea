# Target behavior workbench UI redesign

## Objective

Replace the long vertical review page with a responsive two-column clinical workbench where clinicians can compare source material while drafting a structured E-O-R-C analysis.

## Product decisions

- Desktop uses two columns: inputs/evidence left, formulation/editor right.
- Narrow screens collapse to one column.
- Source selection shows complete authorized note/message content as cards inside a fixed-height internally scrolling feed; no pagination.
- Inbound messages remain first, followed by the existing domain order.
- Left-panel tabs separate cited evidence, clinician observations, and AI proposals.
- Clinician observations remain uncited and do not satisfy the cited-evidence AI guard.
- AI proposals remain in a pending inbox until the clinician manually places their content.
- Existing free-text drafts remain intact as “Previous notes” and are never automatically classified.
- E-O-R-C persists without a migration through a deterministic canonical text representation inside the existing encrypted draft body.

## Constraints and non-goals

- Preserve patient authorization, exact citation validation, encryption, audit, outbox, retention, and RAG indexing contracts.
- Never infer structured clinical meaning from legacy free text or AI output.
- Do not add source pagination, a JavaScript scrolling hook, or schema migrations.
- Use LiveView streams for timeline collections and stable DOM IDs in tests.
- Preserve Spanish UI language and existing project component conventions.
- Do not touch pre-existing untracked `package.json` or `package-lock.json` files.

## Testing configuration

- TDD mode: strict.
- Focused context command: `mix test test/alethea/clinical_record_test.exs`.
- Focused LiveView command: `mix test test/alethea_web/live/target_behavior_live/review_test.exs`.
- Final command: `mix precommit`.
- Visual harness: browser-width inspection if an authorized browser tool is available; otherwise document computed-layout verification as unavailable.

## Delivery

- Branch: `feat/target-behavior-workbench-redesign`.
- Linked approved issue: #309 (`[Feature]: Rediseñar el workbench clínico en dos columnas E-O-R-C`).
- Base: `origin/main` after issue #306.
- Separate from reliability branch `fix/ai-proposal-timeline` so both PRs can be reviewed independently.
- Review budget: 2,718 changed lines because the responsive shell, structured draft contract, and behavior-first tests form one UI workbench capability. One honest slicing pass already separated reliability; the maintainer explicitly accepted the remaining documented size exception before publication.

## Tasks

- [x] **WORKBENCH-UI-1 — Define canonical E-O-R-C draft representation**
  - Status: completed and committed.
  - Route: delegated writer; strict TDD.
  - RED: serializer/parser tests cover round-trip E, O, R, C and pending content plus a legacy free-text fallback.
  - GREEN: add a deterministic deep module that serializes structured fields into the existing encrypted body and returns legacy bodies as previous notes without inference.
  - Allowed edit surfaces:
    - `lib/alethea/clinical_record/functional_analysis_content.ex`
    - `test/alethea/clinical_record/functional_analysis_content_test.exs`
  - TDD evidence: RED failed because the content module was undefined; GREEN focused suite passed 11 tests.
  - Independent verification: confirmed all 11 E-O-R-C fields, deterministic versioned serialization, explicit empties, byte-for-byte legacy fallback, and fail-closed malformed/unsupported envelopes with no inference or migration.
  - Commit evidence: `e499a35` (`feat(clinical): encode structured EORC drafts`).

- [x] **WORKBENCH-UI-2 — Integrate structured draft persistence**
  - Status: completed and committed.
  - Route: delegated writer; strict TDD.
  - Outcome: ClinicalRecord accepts and retrieves canonical structured content while preserving the existing encrypted body, audit, outbox, RAG, retention, and legacy API compatibility.
  - TDD evidence: RED — 5 undefined structured-API failures; GREEN — 84 focused context tests passed.
  - Independent verification: no functional defects; confirmed authorization/target ownership, version-2 encryption, exact canonical ciphertext plaintext, atomic audit/outbox reuse, tombstone behavior, legacy compatibility, and previous-notes-only fallback. Pre-existing untracked package files remain unrelated and untouched.

- [x] **WORKBENCH-UI-3 — Build responsive two-column workbench**
  - Status: completed and committed.
  - Route: delegated writer; strict TDD.
  - Outcome: compact patient/status header, left tabbed inputs, right E-O-R-C editor, responsive fallback, compact observation entry, and readable centered cards.
  - TDD evidence: initial partial implementation produced 11 stale-test failures; migrated behavior tests, added tab/toggle accessibility coverage, and completed roving browser focus through a colocated hook; focused suite now passes 54 tests.
  - Independent verification: confirmed stream-safe tab filtering, responsive two-column/single-column CSS, all 11 structured fields, centered bounded cards, citation/proposal/tombstone preservation, full tab ARIA semantics, observation toggle, and browser focus movement through a contained colocated hook. The source feed remained deliberately unchanged until WORKBENCH-UI-4.
  - Commit evidence: `283f150` (`feat(clinical): redesign behavior workbench`).

- [x] **WORKBENCH-UI-4 — Replace source buttons with full-content feed cards**
  - Status: completed and committed.
  - Route: delegated writer; strict TDD.
  - Outcome: opening citation shows complete source content, metadata, direction, and provenance in domain order inside an internal scroll area while retaining exact-excerpt confirmation.
  - TDD evidence: RED lacked `#evidence-source-feed`; GREEN focused LiveView suite passed 54 tests.
  - Verification evidence: complete content, formatted dates, inbound/outbound/note variants, domain ordering, absence of load-more controls, and exact-excerpt flow are covered; the feed uses bounded internal scrolling and responsive cards.
  - Commit evidence: `283f150` (`feat(clinical): redesign behavior workbench`).

- [x] **WORKBENCH-UI-5 — Add pending proposal inbox and previous notes**
  - Status: completed and committed.
  - Route: delegated writer; strict TDD.
  - Outcome: proposals never auto-populate E-O-R-C; legacy drafts remain visible as previous notes for manual use.
  - TDD evidence: RED — 7 failures for missing inbox/previous-notes UI and legacy merge expectations; GREEN — 58 focused LiveView tests passed.
  - Independent verification: confirmed status-only proposal acceptance leaves structured and legacy drafts byte-identical, creates no clinical note, and keeps accepted proposals visible without pending actions; legacy and structured previous notes remount visibly and remain preserved through saves.
  - Commit evidence: `283f150` (`feat(clinical): redesign behavior workbench`).

- [x] **WORKBENCH-UI-6 — Verify the redesigned workbench**
  - Status: completed.
  - Route: delegated verifier.
  - Checks: focused codec/context/LiveView suite — 153 passed; final LiveView suite — 58 passed; icon suite — 3 passed; `mix precommit` — 1,439 passed, 5 skipped; committed and working diff checks passed; six changed Elixir files reported no diagnostics.
  - Static verification: confirmed two-column and narrow breakpoints, bounded internal source scrolling, stream-safe tabs, contained focus movement, status-only proposal acceptance, previous-notes preservation, citation security, and unchanged authorization/encryption/audit/outbox contracts.
  - Visual verification: unavailable because no browser harness exists in this session; computed layout and browser rendering remain a human review item.
  - Commit evidence: not applicable; verification is read-only.

## Acceptance criteria

- [x] Desktop workbench shows inputs/evidence and analysis editor side by side.
- [x] Narrow screens remain usable in a single-column layout.
- [x] Source feed cards show complete source text before selection.
- [x] Source feed has bounded height and internal scrolling without pagination controls.
- [x] Evidence, observations, and AI proposals use distinct readable cards and filters.
- [x] Evidence cards are centered within a bounded reading width.
- [x] Status metrics render as a compact metadata strip rather than tall KPI tiles.
- [x] Observation entry is compact/collapsible.
- [x] E, O, R, and C fields save and restore independently.
- [x] Legacy text is preserved as previous notes without inferred classification.
- [x] AI proposals stay pending until manually placed.
- [x] Citation confirmation, timeline refresh, and AI evidence guard continue working.
- [x] Existing authorization and clinical-record security tests remain green.

## Progress and evidence

- User screenshots confirmed metadata-only source buttons, unstyled timeline entries, oversized KPI tiles, and a long vertical workflow.
- Read-only mapping confirmed the stylesheet lacks review timeline/card classes and the source adapter already returns complete authorized content in the desired order.
- The existing draft uses one encrypted body; a canonical text codec avoids migrations and preserves downstream RAG indexing.
- User selected internal scrolling, structured E-O-R-C, pending AI proposals, and preservation of legacy drafts as previous notes.
- Workbench implementation committed in `283f150`; source cards show complete content, accessible tabs preserve streamed items, and accepted proposals no longer mutate the draft.
- Compose healthcheck formatting remediation committed separately in `044dc72`; `docker compose config --quiet` and diff check passed with unchanged semantics.
- Unsupported icon found by full precommit was replaced in `cc3f505`; icon coverage and final precommit pass.
- Final verification: focused codec/context/LiveView suite 153 passed; final LiveView suite 58 passed; full `mix precommit` 1,439 passed with 5 skipped; diff checks and diagnostics passed.
- Browser visual verification was unavailable; desktop/mobile rendering remains a human review item.
- Review workload: 2,718 changed lines across nine tracked paths. One honest slicing pass already separated reliability into its own branch; the remaining codec, persistence, UI, CSS, and behavior tests form one integrated workbench capability. The maintainer explicitly accepted the documented size exception.
- Issue #309 was created from the repository feature form and approved by the authenticated repository administrator.
