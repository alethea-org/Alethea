# Proposal — retire-whatsapp-patient-identity (#107)

**Change:** retire the WhatsApp identity surface from patient registration.
**Issue:** alethea-org/Alethea#107 (child of PRD #101).

## Intent

WhatsApp inbound was retired in #87; patient identity now lives on the Foundation Telegram model (`telegram_chat_id_hash`). The legacy `Accounts.Patient` still requires a `whatsapp_number` at registration and carries dead phone columns, a dead phone-lookup reader, and a dead `whatsapp_message_id` dedup path — stale surface with no production data behind it. Remove it cleanly so `alias` becomes the sole registration identity. The one real ripple risk — the shared DEK/KEK envelope — is resolved: it encrypts MESSAGE content (`save_message` → `patient_dek`), not the phone, so it stays fully untouched.

## Scope

### In scope
- `create_patient/2`: drop `whatsapp_number` extraction, blank-check, normalize, encrypt, hash, and both `Map.put` writes. KEEP DEK gen + KEK-wrap + `EncryptionKey` insert + `encryption_key_id` linkage.
- Delete dead `lookup_patient_by_phone/1` + orphaned `normalize_phone/1`.
- `save_message/8`: remove `whatsapp_message_id \\ nil` 6th param + unreachable dedup branch.
- `Patient` schema: drop `whatsapp_number_hash`, `encrypted_whatsapp_number`, virtual `whatsapp_number`, cast entries, unique_constraint.
- `Message` schema: drop `whatsapp_message_id` field, cast, unique_constraint.
- Registration form (`PatientLive.Index`): remove WhatsApp input + privacy-copy line.
- One migration: DROP 3 columns + 2 indexes + the orphaned `whatsapp_consent_logs` table (approved cleanup, zero refs/data).

### Non-goals
- No new uniqueness on legacy `alias`; no KEK/DEK/message-encryption changes; no Foundation Telegram schema changes; not the Telegram invite feature (#108).

## Affected areas

`lib/alethea/accounts.ex`, `lib/alethea/accounts/patient.ex`, `lib/alethea/clinical.ex`, `lib/alethea/clinical/message.ex`, `lib/alethea_web/live/patient_live/index.ex`, one new migration.

## Behavioral contract

- Registration succeeds with alias-only (no whatsapp).
- Message encryption/decryption unchanged (DEK/KEK path intact).

## Test impact

- **BREAKING, same commit as schema drop:** `daily_scheduler_worker_test.exs` struct literals (compile error otherwise); `accounts_test.exs` `create_patient/2` security block + `lookup_patient_by_phone/1` block rewritten/removed.
- **Non-breaking:** ~7 test files with stale `"whatsapp_number"` param keys cleaned up.

## Risks

- Compile-break from struct-key removal (High) → fix `daily_scheduler_worker_test.exs` in same commit.
- `accounts_test.exs` rewrite size (Med) → largest authoring surface, scoped to that block.

## Review workload forecast

Single PR, ~250–350 changed lines (accounts_test rewrite dominates). Within the 400-line budget; no chaining.
