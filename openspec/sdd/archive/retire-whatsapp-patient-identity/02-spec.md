# Spec — retire-whatsapp-patient-identity (#107)

Delta for patient registration (legacy WhatsApp identity retirement).

## MODIFIED Requirements

### Requirement: Patient Registration Identity
The system MUST allow a professional to register a new patient using `alias` as the sole registration identity. The system MUST NOT require, validate, normalize, hash, or encrypt a WhatsApp phone number during registration.
(Previously: registration required a non-blank `whatsapp_number`, normalized, hashed, and encrypted before persistence.)

#### Scenario: Register patient with alias only
- GIVEN a professional submits patient registration with only an `alias`
- WHEN `create_patient/2` is called with no `whatsapp_number` field
- THEN the patient record is created successfully
- AND no whatsapp-number validation error path is triggered

#### Scenario: Registration still provisions patient encryption key
- GIVEN a professional registers a new patient (alias-only)
- WHEN `create_patient/2` completes
- THEN an `EncryptionKey` (DEK) is generated, KEK-wrapped, and linked via `encryption_key_id`
- AND a message subsequently saved for that patient encrypts on write and decrypts on read back to the original plaintext

#### Scenario: Two patients of the same professional may share an alias
- GIVEN a professional already has a patient registered with alias "A"
- WHEN the professional registers a second patient with alias "A"
- THEN the second registration succeeds
- AND no uniqueness constraint violation occurs

### Requirement: Patient Registration Form
The `PatientLive.Index` registration form MUST NOT render a WhatsApp number input or its privacy copy. Submitting the form without a WhatsApp value MUST create the patient.

#### Scenario: Form omits WhatsApp field
- GIVEN a professional opens the patient registration form
- WHEN the form renders
- THEN no WhatsApp number input or WhatsApp privacy copy is present

#### Scenario: Submit form without WhatsApp value
- GIVEN a professional fills only the alias field
- WHEN the form is submitted
- THEN the patient is created
- AND no WhatsApp validation error appears

## ADDED Requirements

### Requirement: Telegram Patient Identity Isolation
The system MUST NOT alter the Foundation Telegram patient identity model (`Foundation.Accounts.Patient`, `telegram_chat_id_hash`) as part of this change.

#### Scenario: Telegram identity model untouched
- GIVEN the Foundation Telegram patient schema and its `telegram_chat_id_hash` uniqueness constraint
- WHEN the WhatsApp retirement migration and code changes are applied
- THEN the Foundation Telegram schema, columns, and constraints remain unchanged

## REMOVED Requirements

### Requirement: WhatsApp Number Uniqueness and Lookup
(Reason: WhatsApp inbound was retired in #87; the phone-hash/lookup path has no production data and no live caller.)
(Migration: `lookup_patient_by_phone/1`, `normalize_phone/1`, `patients.whatsapp_number_hash`, `patients.encrypted_whatsapp_number`, and the `whatsapp_number_hash` unique index are deleted in the same commit as the migration.)

### Requirement: WhatsApp Message Deduplication
(Reason: `whatsapp_message_id` on `Clinical.Message` and the 6th `save_message/8` parameter fed an unreachable dedup branch after #87.)
(Migration: the migration drops `messages.whatsapp_message_id` + its unique index; the orphaned `whatsapp_consent_logs` table is also dropped.)

## Non-requirements (documented)

- No new uniqueness constraint on legacy `Patient.alias`.
- Dead WhatsApp read paths are removed, not preserved — no behavior may depend on them post-merge.
