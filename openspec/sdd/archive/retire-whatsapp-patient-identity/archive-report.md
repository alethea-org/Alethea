# Archive Report — retire-whatsapp-patient-identity (#107)

**Change:** retire the WhatsApp patient-identity surface from registration.
**Issue:** alethea-org/Alethea#107 (CLOSED). Child of PRD #101.
**PR:** #109 (squash-merged to `main` as `aebab6a`).
**Status:** ✅ shipped, verified, adversarially reviewed, merged.
**Store:** hybrid (Engram topic keys `sdd/retire-whatsapp-patient-identity/*`).

## What shipped

WhatsApp inbound was retired in #87; this removed the stale WhatsApp identity surface from patient registration so the patient **alias** is the sole registration identity. No production data, so columns were dropped outright.

- `Alethea.Accounts.create_patient/2` drops the whatsapp-number requirement + hash/encrypt write path. **The DEK/KEK envelope that encrypts message content is fully preserved** (it was never phone-specific) — guarded by an encrypt/decrypt round-trip regression test.
- Dead code deleted: `lookup_patient_by_phone/1`, `normalize_phone/1`, `send_consent_terms/1` (which read the dropped `encrypted_whatsapp_number` and would have raised at runtime), and the `whatsapp_message_id` param + dedup branch of `Clinical.save_message`.
- One reversible `up`/`down` migration drops `patients.whatsapp_number_hash`, `patients.encrypted_whatsapp_number`, `messages.whatsapp_message_id` (indexes cascade with the columns) and the orphaned `whatsapp_consent_logs` table.
- `AletheaWeb.PatientLive.Index` registration form drops the WhatsApp field.
- Removed the now-orphaned `phone_hash_secret` config and cleaned stale WhatsApp doc/comment references (`log_redactor.ex`, `accounts/CONTEXT.md`, `DER.md` ADR-02 marked RETIRADO).

## Delivery

Single PR, net deletion (~214 added / ~366 removed). Full SDD cycle + apply run **inline on Opus** (apply on the Opus model per the user's request; ccm/MiniMax unavailable). Strict TDD. `mix precommit` green (578 passed) on a clean seed-0 run.

## Key design guard

The one real ripple risk — that the patient's DEK/KEK envelope was WhatsApp-only — was investigated and disproved: the DEK encrypts message content via `Clinical.save_message` → `patient_dek`. It stays untouched; only phone-specific lines were removed. Two compile-break atomic groupings were honored (schema-field removal ⟺ `daily_scheduler_worker_test` struct literals; `save_message` signature ⟺ both callers).

## Verify + Judgment Day

- **Verify** initially FAILed on one uncovered spec scenario ("two patients of a professional may share an alias") — fixed by adding the test. Everything else PASS (KEK/DEK intact, migration reversibility proven live, dead readers gone).
- **Judgment Day** ran 2 of 3 judges — the R1 risk lens declined (its native-binding contract refuses an ad-hoc worktree diff; its security scope was independently covered by both remaining judges, which verified the DEK/KEK envelope). **0 blockers.** Fixed in-PR: a stale `save_message` docstring and the orphaned `phone_hash_secret` config. Accepted (intentional, ADR-1): the migration `down` recreates the whatsapp columns nullable (originally `null: false`) so rollback never fails.

## Note

A single flaky test failure appeared in one `mix precommit` run but did not reproduce on a clean seed-0 run (578 passed) — pre-existing suite flakiness (pacer ETS access-rights, `ObanTelemetry` badkey, DB pool delays under load), not introduced here. Stabilizing those flaky tests is a candidate follow-up.

## Follow-ups

- **#108** — Telegram invite action (professional dashboard) — the sibling child of PRD #101, still open. Completes the "usable onboarding" half of #101.

## Feature status

PRD #101's first slice is complete. Registration is now WhatsApp-free with alias-only identity; #108 adds the professional-facing Telegram onboarding action.
