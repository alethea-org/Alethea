# Tasks — retire-whatsapp-patient-identity (#107)

**Delivery:** single PR (~250-350 lines). **400-line budget risk: Low.** No chaining. Strict TDD (RED-first where genuinely testable; GREEN-only regression proof for the pure-removal atomic groups).

> **Two ATOMIC groups (do NOT split — else the tree won't compile):**
> 1. `save_message` signature change ⟺ both call sites.
> 2. `Patient` schema field removal ⟺ `daily_scheduler_worker_test.exs` struct-literal fix.

## Phase 1 — save_message signature retirement · **[ATOMIC — do not split]**
- [x] `Clinical.save_message`: drop the `whatsapp_message_id` param, the `if whatsapp_message_id` attrs block, the whatsapp dedup `cond` branch; trim `{:error, :duplicate}` from the `@spec`.
- [x] Fix BOTH callers in the same step: `clinical.ex:144` (`save_telegram_message/6`) and `test/alethea_jobs/session_timeout_worker_test.exs:43`.
- [x] `Message` schema: drop `whatsapp_message_id` field, cast, unique_constraint.
- [x] GREEN on clinical/message/session_timeout tests (no red-first possible for a removal).

## Phase 2 — Patient schema field removal · **[ATOMIC — do not split]**
- [x] `patient.ex`: remove `whatsapp_number_hash`, `encrypted_whatsapp_number`, virtual `whatsapp_number`, their cast entries, `unique_constraint(:whatsapp_number_hash)`.
- [x] SAME step: fix `daily_scheduler_worker_test.exs` struct literals (:34-42, 45-53, 81-89) — compile break otherwise.
- [x] GREEN after (verified post-migration; DB columns were NOT NULL until Phase 3).

## Phase 3 — Migration (after Phases 1-2)
- [x] Create `priv/repo/migrations/20260805232851_retire_whatsapp_patient_identity.exs` with the exact up/down from the design (remove 3 columns — NO explicit drop index, Postgres cascades; `drop table(:whatsapp_consent_logs)`; `down` recreates all).
- [x] `mix ecto.migrate`, then `mix ecto.rollback` (proves `down`), then re-migrate — all GREEN.

## Phase 4 — accounts_test.exs RED
- [x] Delete `describe "lookup_patient_by_phone/1"` (:191-220); delete whatsapp assertions in the create_patient describe.
- [x] ADD: (a) alias-only create → `{:ok, patient}`; (b) EncryptionKey "patient" provisioned + `encryption_key_id` set; (c) missing alias → `{:error, changeset}`; (d) **message encrypt/decrypt round-trip via the provisioned DEK** (mandatory encryption regression — guards the KEK/DEK survival).
- [x] Run — RED confirmed (4/5 fail against current `accounts.ex`).

## Phase 5 — accounts.ex GREEN
- [x] `create_patient/2`: strip phone lines (extraction, blank-check cond, normalize call, encrypt, hash, the two `Map.put`) + delete the `send_consent_terms(patient)` call. KEEP DEK/KEK/EncryptionKey Multi untouched.
- [x] Delete dead `lookup_patient_by_phone/1`, `normalize_phone/1`, and `send_consent_terms/1` (reads the dropped field → runtime KeyError if left). Also dropped now-unused `require Logger`.
- [x] GREEN on accounts_test (5 passed).

## Phase 6 — PatientLive.Index form
- [x] RED: LiveView test (`test/alethea_web/live/patient_live/index_test.exs`) — form has no whatsapp field, alias-only submit works.
- [x] GREEN: remove the WhatsApp input block (:291-308) + privacy-copy line (:270); trim badge to channel-neutral copy.

## Phase 7 — Stale-param cleanup (non-breaking)
- [x] Drop ignored `"whatsapp_number"` keys across: `telegram_onboarding_worker_test`, `telegram_message_worker_reminder_test`, `telegram_message_worker_test`, `session_manager_test`, `weekly_report_worker_test`, `session_timeout_worker_test` (distinct edit from its Phase 1 positional-arg fix), `dashboard_live_test`.

## Phase 8 — `mix precommit` green
- [x] Full `mix precommit` (compile --warnings-as-errors + format --check-formatted + test) GREEN.

## Review Workload Forecast
- ~250-350 changed lines (accounts_test rewrite dominates). 400-budget risk **Low**. Single PR, no chaining.
- Load-bearing: Phase 3 (migration) runs AFTER Phases 1-2. `send_consent_terms/1` deleted in Phase 5 (KeyError trap). `session_timeout_worker_test.exs` edited twice (Phase 1 atomic + Phase 7 cleanup) — distinct diffs.
