# Issue 303 — Target behavior creation

## Objective

Let an authorized clinician create a target behavior from the selected patient's dashboard and continue directly to its functional-analysis workbench.

## Scope

- Add a patient-scoped "Nueva conducta objetivo" dashboard action.
- Add an authenticated, dedicated LiveView creation route and form.
- Persist through `ClinicalRecord.create_target_behavior/3` only.
- Show clear validation/error feedback and patient context.
- Support cancellation without persistence.
- Redirect successful creation to `/patients/:patient_id/target_behaviors/:id/review`.
- Cover dashboard entry, rendering, validation, creation, cancellation, and professional/patient isolation.

## Constraints and non-goals

- Reuse the existing authenticated professional LiveView session.
- Never trust a professional or patient identity submitted by the client.
- Keep encryption, audit, and outbox behavior inside `ClinicalRecord.create_target_behavior/3`.
- Use `to_form/2`, `<.form>`, and `<.input>` with stable DOM IDs.
- Do not redesign prototype views or change schemas, migrations, encryption, or context persistence.
- Existing Spanish UI language is preserved; technical artifacts remain in English.

## Testing configuration

- TDD mode: strict.
- Runner: `mix test`.
- Focused command: `mix test test/alethea_web/live/target_behavior_live/new_test.exs test/alethea_web/live/dashboard_live_test.exs`.
- Final command: `mix precommit`.

## Delivery and review

- Current branch: `feat/303-target-behavior-creation`.
- Base: `origin/main` at `05786f085af95c7465468a001ac62e6699a28cea`.
- Base capability: issue #292 target-behavior dashboard listing.
- Delivery strategy: one feature PR closing approved issue #303.
- Review workload: 415 changed lines before final evidence; maintainer explicitly accepted `size:exception` because the cohesive change exceeds the 400-line budget by 15 lines, including 94 lines of ODD evidence.
- Expected change: five bounded implementation/test files plus this evidence document; one cohesive work unit.

## Tasks

- [ ] **TB-CREATE-1 — Specify and implement the creation flow**
  - Status: implemented and independently verified; commit/push/PR authorized.
  - Route: delegated writer; multi-file write trigger.
  - RED: add LiveView tests for dashboard entry, form context, blank validation, successful creation/redirect, cancellation, and unauthorized access.
  - GREEN: add the route, dedicated LiveView, and dashboard action using `ClinicalRecord.create_target_behavior/3`.
  - REFACTOR: preserve stable IDs, authenticated patient scoping, and concise error handling.
  - Allowed edit surfaces:
    - `lib/alethea_web/router.ex`
    - `lib/alethea_web/live/dashboard_live.html.heex`
    - `lib/alethea_web/live/target_behavior_live/new.ex`
    - `test/alethea_web/live/target_behavior_live/new_test.exs`
    - `test/alethea_web/live/dashboard_live_test.exs`
  - TDD evidence: RED focused suite — 42 passed, 6 failed, 1 skipped because the route, form, and dashboard action were absent; GREEN/refactor focused suite — 48 passed, 1 skipped.
  - Writer checks: `mix precommit` — 1385 passed, 5 skipped; `git diff --check` passed.
  - Runtime evidence: valid submission trimmed and encrypted the description, enqueued the outbox event, displayed success feedback, and navigated to the exact new workbench.
  - Rollback evidence: blank submission, cancellation, and unauthorized mount created no target behavior or outbox job.
  - Commit evidence: pending creation.

- [x] **TB-CREATE-2 — Verify the complete issue behavior**
  - Status: completed.
  - Route: delegated verifier; verification trigger.
  - Checks: focused issue suite — 48 passed, 1 skipped; workbench regression suite — 38 passed; `mix precommit` — 1385 passed, 5 skipped; `git diff --check` passed; supported changed-file LSP diagnostics reported no findings.
  - Runtime evidence: the successful UI flow creates encrypted data, enqueues the patient/professional-scoped outbox event, redirects with visible success feedback, and exposes the same behavior plus exact workbench link on the patient dashboard.
  - Architecture note: LiveViews inherit `{AletheaWeb.Layouts, :app}` from `use AletheaWeb, :live_view`; manually adding `<Layouts.app>` would duplicate the shell because this repository's layout consumes `@inner_content`.
  - Native review: unavailable because the verified package-local Gentle AI binary is missing; no lineage was created and no mutation occurred.
  - Commit evidence: not applicable; this verification task is read-only.

## Acceptance criteria

- [ ] The selected patient's dashboard exposes "Nueva conducta objetivo" beside clinical notes.
- [ ] The action opens a dedicated form identifying the patient.
- [ ] A valid description creates a target behavior and shows success feedback.
- [ ] The created behavior is available on the patient dashboard and links to its workbench.
- [ ] Cancellation creates no record.
- [ ] Unauthorized professionals cannot create a behavior for another patient's record.
- [ ] Persistence retains the existing encryption, audit, and outbox flow.
- [ ] Validation and operational errors are visible and clear.
- [ ] LiveView tests cover all requested paths.

## Progress and evidence

- Issue #303 requirements inspected.
- Read-only repository mapping completed by `gentle-ai-explore`.
- No unresolved product decision remains.
- The bounded writer implemented the five planned source/test surfaces without modifying the domain context.
- Independent verification initially identified a missing end-to-end dashboard assertion; the success test now verifies the newly created behavior and its exact workbench link on the dashboard.
- Changed-file LSP diagnostics reported no findings for supported Elixir files; HEEx diagnostics were unavailable because no HEEx LSP is configured.
- Final verification passed on the original base: focused issue suite 48 passed/1 skipped, review regression suite 38 passed, and full `mix precommit` 1385 passed/5 skipped.
- Reverification from current `origin/main`: focused issue suite 48 passed/1 skipped and full `mix precommit` 1395 passed/5 skipped.
- `mix precommit` normalized pre-existing whitespace in `review.ex`; that out-of-scope formatter mutation was rolled back exactly before staging.
- Issue #303 was explicitly approved for delivery and now carries `status:approved`.
- Native review inspection was blocked by a missing package-local binary; it created no lineage and performed no mutation.
