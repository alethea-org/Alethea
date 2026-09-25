# Issue #319 — E-O-R-C draft generation in the Workbench

## Objective and scope

Add a prominent draft-generation action to the target-behavior review editor. Feed the existing #316 local functional-analysis chain with the authorized, cited timeline excerpts; fill only blank E-O-R-C fields, preserve existing and unsaved clinician text including `previous_notes`, display feedback, and leave persistence to the standard Save action. Do not change the chain, automatically save, or send uncited evidence to the model.

Issue: https://github.com/alethea-org/Alethea/issues/319 (depends on closed #316). Branch: `feat/319-eorc-draft-button`, based on `origin/main` at `e261522`. Pre-existing untracked `package.json` and `package-lock.json` are excluded from this feature.

## Constraints and decisions

- Use the existing `ClinicalRecord.review_timeline/3` authorization and citation boundary and `FunctionalAnalysisDraftChain.run/1` contract. Sanitize every selected cited excerpt before passing it to the chain.
- The eleven E-O-R-C fields are distinct from `previous_notes`; only genuinely blank fields receive generated text. A late response must not overwrite intervening edits or populate content derived from a citation legally deleted during generation. Deletion of the original source does not invalidate its independently retained citation. A failed, stale, or empty generation leaves the editor unchanged.
- TDD mode: strict, from `openspec/config.yaml` and the established ODD feature-document convention. Focused runner: `mix test test/alethea_web/live/target_behavior_live/review_test.exs`; final runner: `mix precommit` (inspect `mix help precommit` first).
- Delivery strategy: `exception-ok`, explicitly selected by the user after the cohesive implementation reached 536 authored source/test lines. One work-unit commit and a possible single PR; no PR or push without a user request. Review candidate is the work-unit commit, not a checklist item. RDD switch rendered on in this session; use native assessment at commit boundary.
- Engram mirror: pending until provider recovers (current provider reports server/CLI instance-identity incompatibility). Local file is authoritative until resynchronized.

## Tasks

- [x] **EORC-319-1 — Generate and merge an editable draft from cited evidence.** Route: delegated writer (multi-file LiveView and LiveView tests). Implemented the header action, sanitized cited evidence handoff, async safe merge, authorization and citation-liveness rechecks, standard explicit Save, and failure feedback. Work-unit commit `224f6279b2517ecd7957896b3013e0af58c4e437` (`feat(clinical): generate E-O-R-C draft from citations`). Checks and review evidence below.

## Progress and evidence

- Exploration: #316 landed on `origin/main`; review editor is `lib/alethea_web/live/target_behavior_live/review.ex`, existing LiveView tests are `test/alethea_web/live/target_behavior_live/review_test.exs`, and cited excerpts come from `ClinicalRecord.review_timeline/3`.
- Writer TDD: initial RED 83/87, GREEN focused 87/87; verifier found a deleted-citation completion race. A scoped challenge confirmed deleted citations disappear from the live timeline, whereas deletion of their original source preserves the citation. Corrective RED 87/88, GREEN 88/88. Independent post-correction focused rerun: 88/88; `git diff --check` passed. Chain regression 24/24; `mix precommit` passed (1,568 tests + 6 doctests, 5 skipped, nonfatal pre-existing warnings). Browser runtime harness N/A: behavior exercised via LiveView integration tests and a configured chain mock; no authorized browser scenario available.
- Committed work unit `224f6279b2517ecd7957896b3013e0af58c4e437`, 561 authored lines including this document. User chose `exception-ok` for one cohesive PR slice; no push/PR requested. Native assessment before and after commit was unassessable due undeclared untracked files, so independent verification ran. `inspect` explicitly excluded those untracked files; native committed-only review classified this work-unit candidate **medium**, selected `review-reliability`, approved and acknowledged lineage `review-e153b6d6eb08db17` (authority burned). This review does not authorize delivery. Progress-record evidence was committed separately as passive documentation in `06e2703`.
- Delivery: #319 has `status:approved`. Integrated #327/#317 from `origin/main` in merge commit `9b3a1e5`, preserving both sides of the one test conflict. Post-merge delegated verification passed: format check, Workbench 98 tests, draft chain 24 tests, clinical-record/transcript suites 151 tests, and `mix precommit` 1,615 tests with 5 skipped. Committed-only PR-slice native review was medium/reliability, approved and acknowledged (`review-138bed6ef5fd1810`, authority burned). Branch pushed to `origin/feat/319-eorc-draft-button`; PR [#352](https://github.com/alethea-org/Alethea/pull/352) targets `main`, links `Closes #319`, has exactly one `type:feature` label, and documents the accepted 564-line size exception. Pre-existing untracked `package*.json` remain excluded.
- Next step: wait for PR #352 CI checks (Format check and Test pending at creation) and human review; no merge authorized. Engram mirror remains pending provider recovery.
- Rollback boundary: the #319 LiveView event/editor wiring, its focused tests, and this feature document; preserve unrelated branch and untracked files.
