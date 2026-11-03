# Trigger management and dashboard summary — issue #442
Objective: deliver #442 on `feat/442-trigger-management`; delivery: feature-branch-chain (no push/PR/merge authorized).
Runner: focused `mix test` at context, worker and LiveView public seams, then `mix precommit`; initial forecast 900–1200 authored lines; T1 exceeded forecast (~1600 with regression fixtures), kept as one cohesive high-risk backend unit.

## Specs
S1. "The professional can activate and deactivate a trigger without deleting it." "A deactivated trigger never fires; reactivating it resumes scheduling."
S2. "Editing a Trigger activo's instruction clears the approved text; it does not send again until a new preview is approved." "After an instruction edit, no send happens until a new preview is approved."
S3. "Edits and status changes appear in the audit log."
S4. "The patient dashboard shows a triggers summary card (counts by kind and status) linking to the Triggers page." "The summary card reflects the current triggers."
S5. Inherited #440 constraint: "Only the patient's owning professional can see or edit triggers. Every mutation writes an audit log entry."
S6. Accepted recommendation: "No permitir reactivarlo (recomendado)" / "Informar que venció y pedir crear uno con un horario futuro; evita un envío inesperado."

## Tasks
T1 | S1-S3,S5-S6 | delegated gentle-ai-worker (context backstop at 81,935 tokens); done | backend implemented; parent 92 initial + 18 corrected focused tests passed; independent verifier PASS after one correction batch; work-unit commit being recorded. Risk: item 4 (serialize lifecycle changes with firing/delivery), item 2 (owner-scoped clinical mutations), item 1 (stored approval migration).
T2 | S1-S3,S5-S6 | delegated gentle-ai-worker (context backstop); pending | trigger management LiveView and tests/docs; commit pending.
T3 | S4-S5 | delegated gentle-ai-worker (context backstop); pending | patient dashboard counts by active/reactive kind and status, tests/docs; commit pending.
T4 | S1-S6 | parent + independent gentle-ai-verify (named high-risk items) | pending | focused spot check, mix precommit, independent functional verification, native assess/review when due; final commit evidence pending.

## Log
L1. User: "hagamos la issue [Feature]: Edit, activate and deactivate triggers + dashboard summary card #442."
L2. #442 read from https://github.com/alethea-org/Alethea/issues/442; dependency #440 is CLOSED; #441 recurrence merged at base c2d21ea8bba6e921eec4016a721068aa36902c29. Original clean branch main. RDD globally on.
L3. Explorer mw01orvw-1-fjva mapped context, worker, schema and LiveViews. Parent spot-read context/worker/schedule/schema/test runner/tests. Corrected explorer interpretation: kind is active/reactive, not schedule_type. Reactive triggers are not implemented yet; do not invent them for this issue.
L4. User: "Review the delivered subagent output and continue."
L5. Asked delivery: feature-branch-chain (recommended), stacked-to-main, or single-pr; asked overdue one-shot behavior: reject activation (recommended), or immediate send. First questionnaire cancelled. User: "lo que reocmiendes". Adopted recommended feature-branch-chain and reject overdue one-shot activation; shape selection is not delivery authorization. Recurring resumption must reuse timezone/end-date scheduling helpers, not catch up missed sends.
L6. Risk focus: nullable approved_text currently prohibited by DB/schema; worker uses FOR UPDATE. All lifecycle mutations must use the same lock, encrypted fields and content-free audits. Unapproved triggers and deactivated triggers must not create firings/outbound sends. Preserve server-owned preview/instruction binding, including stale concurrent previews. Pending outbound retries need review at the actual delivery seam; already-sent messages cannot be recalled.
L7. Work-unit forecast exceeds 400; keep coherent behavior with tests/docs, no cosmetic shrinking, no policy exception assumed. Parent delegates next bounded multi-step work due measured context backstop. Final verification covers every spec; no publishing authorized.
L8. T1 writer mw0256ke-2-nh0h implemented lifecycle APIs and guards; parent focused command passed 92 tests, exit 0. ASSESS unassessable due undeclared untracked scope; named item4 escalation requires independent verify. Verifier mw02pvxj-3-yjis reproduced missing revision on legacy outbound jobs and optional expected_revision bypass in reapproval (S2 FAIL). One correction batch mw03209p-4-gek4 added mandatory positive snapshot and legacy revision1 fallback; writer reports 95 focused tests and compile warnings-as-errors green, plus safe/crisis differential against base (37 tests on each, exit0, no normalized semantic differences). Limited recheck mw03cua6-5-9ali running; T1 is NOT complete yet.
L9. Delivery boundary: local pre-send gate cannot recall HTTP already in flight. Verifier treats that and suppressed messages remaining pending as advisories, not blockers. Worker risk:none reports are not accepted: item4 concurrency/item2 authorization/item1 migration remain the verification basis.
L10. T1 limited recheck mw03cua6-5-9ali PASS on both original blockers: 18 focused tests exit0, plus scratch legacy revision1/revision2 probe. Independent verifier accepted fixed-seed base/candidate safe/crisis differential. Parent reran same 18 focused tests exit0 and git diff --check clean. T1 backend is functionally verified; native assessment/review follows at the commit boundary. No production migration executed.
