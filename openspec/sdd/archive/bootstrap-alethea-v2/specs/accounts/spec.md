# Accounts Foundation Specification

## Purpose

Defines the canonical Ecto schemas for the three roles of Alethea (Psicólogo, Paciente, Admin) and the tenant-scope helper, using the field names from `UBIQUITOUS_LANGUAGE.md`. Lives in `Alethea.Foundation.Accounts.*` as a parallel, non-breaking addition to the legacy `Alethea.Accounts.*`.

This is a foundation capability, not a feature. The full auth flows, password reset, MFA enrollment, etc. belong to future changes (`psicologo-foundation`, `admin-foundation`). This spec covers only: schema shape, FK relationships, and the tenant scope helper.

## Requirements

### Requirement: Professional Schema Shape

The system MUST provide `Alethea.Foundation.Accounts.Professional` as an Ecto schema with a UUID primary key and the following canonical fields.

| Field | Type | Required | Notes |
|---|---|---|---|
| `id` | `binary_id` (UUID v4) | yes (PK) | autogenerate |
| `email` | `:string` | yes | unique, validated as RFC-5322 subset |
| `password_hash` | `:string` | yes | never exposed in JSON |
| `full_name` | `:string` | yes | at signup; mutable later |
| `mfa_secret` | `:string` (encrypted) | no | added when MFA is enrolled, in `psicologo-foundation` |
| `crisis_message` | `:string` | no | per-patient message text used by the crisis protocol |
| `remember_token_hash` | `:binary` | no | filled by auth, not signup |
| `remember_token_expires_at` | `:utc_datetime` | no | filled by auth |
| `inserted_at`, `updated_at` | `:utc_datetime` | yes | standard Ecto |

The system MUST enforce uniqueness on `email` (case-insensitive lookup helper provided).

#### Scenario: A new professional signs up with the minimum required fields

- GIVEN the `professionals` table is empty
- WHEN `Alethea.Foundation.Accounts.register_professional(%{email: "ana@example.com", password: "supersecret12", full_name: "Ana Pérez"})` is called
- THEN the returned struct has `email == "ana@example.com"`, `password_hash` set, and `id` populated
- AND `password_hash` is NOT equal to the plaintext password
- AND the row is persisted in the `professionals` table

#### Scenario: Signup with a duplicate email is rejected

- GIVEN a professional with `email == "ana@example.com"` already exists
- WHEN `register_professional(%{email: "ana@example.com", ...})` is called
- THEN the result is `{:error, %Ecto.Changeset{}}` with `:email` in `errors`
- AND no new row is inserted

#### Scenario: Signup with invalid email format is rejected

- GIVEN the email field is `"not-an-email"`
- WHEN `register_professional/1` is called
- THEN the result is `{:error, %Ecto.Changeset{}}` with `:email` error
- AND no row is inserted

#### Scenario: Signup with a password shorter than 12 chars is rejected

- GIVEN the password is `"short"`
- WHEN `register_professional/1` is called
- THEN the result is `{:error, %Ecto.Changeset{}}` with `:password` error

### Requirement: Patient Schema Shape

The system MUST provide `Alethea.Foundation.Accounts.Patient` as an Ecto schema with a UUID primary key, a non-nullable `professional_id` FK, and the canonical profile fields from `UBIQUITOUS_LANGUAGE.md` (Perfil del paciente section).

| Field | Type | Required | Notes |
|---|---|---|---|
| `id` | `binary_id` (UUID v4) | yes (PK) | autogenerate |
| `professional_id` | FK → `professionals.id` | yes | tenant boundary |
| `alias` | `:string` | yes | display name shown to professional |
| `status` | `:string` enum | yes | one of `active`, `archived`, `deleted`; default `active` |
| `telegram_chat_id` | `:string` | no | populated by `telegram-paciente-foundation` |
| `profile_name` | `:string` | no | patient's actual name (Perfil del paciente) |
| `profile_birth_date` | `:date` | no | (Perfil del paciente) |
| `profile_gender` | `:string` | no | (Perfil del paciente) |
| `profile_language` | `:string` | no | (Perfil del paciente) |
| `profile_email` | `:string` | no | optional (Perfil del paciente) |
| `emergency_contact_name` | `:string` | no | (Perfil del paciente) |
| `emergency_contact_relationship` | `:string` | no | (Perfil del paciente) |
| `emergency_contact_phone` | `:string` | no | (Perfil del paciente) |
| `inserted_at`, `updated_at` | `:utc_datetime` | yes | standard Ecto |

The system MUST enforce that `professional_id` is not null. On `delete_all` of the professional, the FK action is the orchestrator's decision (proposed: `nilify_all` in this change, realigned with legacy behavior; can be changed in a later data-migration change).

#### Scenario: Creating a patient bound to a professional

- GIVEN a professional exists
- WHEN `Alethea.Foundation.Accounts.create_patient(professional, %{alias: "JP"})` is called
- THEN the result is `{:ok, %Patient{}}` with `professional_id == professional.id` and `status == "active"`

#### Scenario: Creating a patient without a professional is rejected

- GIVEN no professional context is provided
- WHEN `create_patient(nil, %{alias: "JP"})` is called
- THEN the result is `{:error, %Ecto.Changeset{}}` with `:professional_id` error

#### Scenario: The `status` field accepts only the three canonical values

- GIVEN a patient exists
- WHEN `update_patient(patient, %{status: "frozen"})` is called
- THEN the result is `{:error, %Ecto.Changeset{}}` with `:status` error

### Requirement: Admin Schema Shape

The system MUST provide `Alethea.Foundation.Accounts.Admin` as an Ecto schema with a UUID primary key and a minimal identity shape. Admins do not own patients and do not have a `professional_id` FK (per `CONTEXT.md`: "Admin: Web (LiveView) — billing, RevenueCat, soporte, onboarding. Sin acceso a datos clínicos").

| Field | Type | Required | Notes |
|---|---|---|---|
| `id` | `binary_id` | yes (PK) | autogenerate |
| `email` | `:string` | yes | unique |
| `password_hash` | `:string` | yes | never exposed |
| `role` | `:string` | yes | enum: `"superadmin"`, `"support"`, `"billing"` |
| `inserted_at`, `updated_at` | `:utc_datetime` | yes | standard Ecto |

#### Scenario: Admin signup is independent of professionals

- GIVEN the `professionals` and `admins` tables are empty
- WHEN `Alethea.Foundation.Accounts.register_admin(%{email: "ops@alethea.app", password: "longenoughpw1", role: "superadmin"})` is called
- THEN an `Admin` row is inserted
- AND no `Professional` row is created
- AND the admin's `role` is persisted

#### Scenario: Admin with invalid role is rejected

- GIVEN `role: "godmode"` is invalid
- WHEN `register_admin/1` is called
- THEN the result is `{:error, %Ecto.Changeset{}}` with `:role` error

### Requirement: Tenant Scope Helper

The system MUST provide `Alethea.Foundation.Tenant.scope_query/2` that takes an `Ecto.Queryable` and a `professional_id` (UUID binary) and returns a query scoped to rows owned by that professional. For `Patient`, this MUST filter on `patient.professional_id == ^professional_id`.

The helper MUST be a pure function with no I/O side effects, suitable to be composed into a Repo call.

#### Scenario: Scoping a `Patient` query to a tenant

- GIVEN a query `%Ecto.Query{}` over `Alethea.Foundation.Accounts.Patient`
- WHEN `Alethea.Foundation.Tenant.scope_query(query, "prof-uuid-1")` is called
- THEN the resulting query has a `WHERE professional_id = ^"prof-uuid-1"` clause
- AND when the query is executed against a Repo with two patients (one with `professional_id == "prof-uuid-1"`, one with `"prof-uuid-2"`), only the first is returned

#### Scenario: Scoping with `nil` is rejected

- GIVEN a query
- WHEN `scope_query(query, nil)` is called
- THEN the function raises `ArgumentError` with a clear message ("professional_id must not be nil")

#### Scenario: Scoping with a non-UUID binary is accepted at this layer (validation is upstream)

- GIVEN a query
- WHEN `scope_query(query, "not-a-uuid")` is called
- THEN the function does not raise and returns a query with `WHERE professional_id = ^"not-a-uuid"`
- AND validation of UUID format is the caller's responsibility (logged for future tightening)
