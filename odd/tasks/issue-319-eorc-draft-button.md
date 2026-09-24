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

- [ ] **EORC-319-1 — Generate and merge an editable draft from cited evidence.** Status: in progress. Route: delegated writer (multi-file LiveView and LiveView tests). Add RED tests, implement editor action and safe non-destructive merge, then GREEN/refactor, including evidence authorization, sanitization, failure, deleted-citation races, and stale/unsaved-edit behavior. Check: focused LiveView suite, #316 chain regression suite, `mix precommit`; inspect UI/runtime if available or record explicit N/A. Keep tests and behavior in one Conventional Commit and record its identity, native assessment, and review outcome here. Next step: delegate bounded writer after this file and mirror are read back.

## Progress and evidence

- Exploration: #316 landed on `origin/main`; review editor is `lib/alethea_web/live/target_behavior_live/review.ex`, existing LiveView tests are `test/alethea_web/live/target_behavior_live/review_test.exs`, and cited excerpts come from `ClinicalRecord.review_timeline/3`.
- Writer TDD: initial RED 83/87, GREEN focused 87/87; independent focused rerun 87/87. Native pre-commit assessment unassessable because untracked files lacked declaration; verifier identified a deleted-citation completion race. A scoped assumption challenge confirmed deleted citations disappear from the live timeline, whereas deletion of their original source preserves the citation. Corrective RED 87/88, GREEN 88/88. Chain regression 24/24; `mix precommit` 1,568 tests + 6 doctests, 5 skipped; `git diff --check` passed. Current source/test diff: 533 additions, 3 deletions. User selected `exception-ok` for this cohesive ~536-line unit. Pending: independent post-correction check, commit, candidate assessment/review, final readback. No implementation commit exists.
- Rollback boundary: the #319 LiveView event/editor wiring, its focused tests, and this feature document; preserve unrelated branch and untracked files.
