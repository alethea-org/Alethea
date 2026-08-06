# Exploration — retire-whatsapp-patient-identity (#107)

**Change:** retire the WhatsApp identity surface from patient registration.
**Issue:** alethea-org/Alethea#107 (child of PRD #101).
**Branch:** `feat/retire-whatsapp-patient-identity` off `main` (5c01b83).
**Status:** Explore done — mostly verification; removal is clean/mechanical. One scope question (consent_logs table).

## The ripple risk — RESOLVED: KEK/DEK stays

The patient's DEK (generated in `create_patient/2`, wrapped by the professional's KEK into `EncryptionKey`) is the **same key that encrypts message content** (`Clinical.save_message/8` → `get_dek/2` → `patient_dek/1`; decrypted for display in `dashboard_live.ex`). It is **not** WhatsApp-only. → Do NOT touch DEK generation, the `EncryptionKey` insert, or `encryption_key_id`. Remove only the phone-specific lines inside `create_patient/2`.

## Removal surface (file:line)

1. **`create_patient/2`** (`accounts.ex:238-328`): remove `whatsapp_number` extraction (:242), the blank-check `cond` that errors (:244-252), `normalize_phone/1` call (:256), phone encrypt (:265), phone hash block (:268-275), the two `Map.put` of `encrypted_whatsapp_number`/`whatsapp_number_hash` (:292-293). Keep alias/professional, DEK generation (:259), KEK wrap (:262), `EncryptionKey` Multi insert, consent/pubsub/audit side-effects.
2. **`lookup_patient_by_phone/1`** (`accounts.ex:174-190`, `Repo.get_by(Patient, whatsapp_number_hash:)`): dead — only caller is its own test (`accounts_test.exs:206-218`). Delete. `normalize_phone/1` (`accounts.ex:337-344`) is private with exactly 2 callers (this fn + create_patient) — dead after both removals, delete.
3. **`whatsapp_message_id`** in clinical: `save_message/8` 6th param `whatsapp_message_id \\ nil` (`clinical.ex:28-87`); only prod caller `save_telegram_message/6` passes `nil` (:150); dedup branch (:67-72) unreachable. Remove the param + dedup branch.
4. **Registration form** (`patient_live/index.ex`): remove the WhatsApp input block (:291-308) + the privacy-copy line referencing WhatsApp (:270). `handle_event("save")` already forwards `patient_params` + `professional_kek` unchanged.
5. **Migration** — drop: `patients.whatsapp_number_hash`, `patients.encrypted_whatsapp_number`, unique index `patients_whatsapp_number_hash_index`, `messages.whatsapp_message_id` + its partial unique index. No other migration references these.
6. **Schema/changeset**: `patient.ex` fields :8-9 + virtual :19, cast :35-37, `unique_constraint(:whatsapp_number_hash)` :53-55. `message.ex` field :10, cast :39, `unique_constraint(:whatsapp_message_id)` :62.

## Test surface

- **Compile-breaking (must land same commit as schema drop):** `daily_scheduler_worker_test.exs:34-53,81-89` builds raw `%Patient{whatsapp_number_hash: ..., encrypted_whatsapp_number: ...}` struct literals → unknown-key compile error once fields drop.
- **Rewrite required:** `accounts_test.exs` — the `describe "create_patient/2 y Seguridad"` block (:22-189, tests the removed whatsapp encrypt/hash/uniqueness/validation) and `describe "lookup_patient_by_phone/1"` (:191-220, tests the deleted fn).
- **Non-breaking cleanups** (stale `"whatsapp_number"` param, silently ignored): `telegram_onboarding_worker_test.exs:706`, `telegram_message_worker_reminder_test.exs:201`, `telegram_message_worker_test.exs:1746`, `session_manager_test.exs:18`, `weekly_report_worker_test.exs:26`, `session_timeout_worker_test.exs:28`, `dashboard_live_test.exs:112`.
- `test/alethea/foundation/**` targets the Telegram-identity schema — unrelated, out of scope.

## Open scope question

- **`whatsapp_consent_logs` table** (`20250601160000_add_whatsapp_consent_logs.exs`): orphaned, zero live code references (the ConsentLog/ConsentCache code was deleted in #87 but the TABLE remains). NOT named in #107's acceptance criteria → needs owner sign-off before dropping.

## Risks
- `daily_scheduler_worker_test.exs` struct literals fail to **compile** the instant fields drop — schema change + that test fix must be one commit.
- `accounts_test.exs` is the largest authoring surface (substantial rewrite).
