# Exploration — session-transcript-317 (#317)

**Status:** exploration complete
**Issue:** #317 — Esquema y persistencia de SessionTranscript con oradores
**Parent:** #314 — Spec: Semantic evidence discovery, E-O-R-C auto-drafting, and session audio transcriptions

## Executive summary

`SessionTranscript` is greenfield: zero `session_transcript` references exist in `lib/`, `priv/`, or `openspec/`. However, four strong precedents fully determine its shape, and one widely-assumed pattern is wrong. Patient clinical data in Alethea is **not** encrypted with `Cloak.Ecto` field types — Cloak is used only for one infrastructure secret. Patient data uses manual AES-256-GCM envelope encryption (`Alethea.Encryption.PatientVault`) with a per-patient DEK wrapped by the professional's KEK, stored as `encrypted_* :binary` + `encryption_version :integer` + a `virtual: true, redact: true` plaintext field. Structured payloads (the E-O-R-C content from #316) are serialized to a single canonical plaintext string and encrypted as one blob — there is no `Ecto.Type` + Cloak layering anywhere in the codebase. Authorization already lives in the context layer (`Accounts.get_patient_for_professional/2` → KEK → DEK ladder), so criterion 4 has an exact template. Recommended home: `Alethea.ClinicalRecord.SessionTranscript` / table `session_transcripts` (the name `clinical_sessions` is already taken by the Telegram journaling session).

## Current state

### 1. Patient-level encryption — the real mechanism

Two encryption systems coexist and must not be confused.

**(a) Cloak vault — NOT for patient data.** `lib/alethea/encryption/vault.ex:1-16` is a `use Cloak.Vault` with a single vault-wide AES-GCM key decoded from `config[:aes_key]`. `lib/alethea/encryption/types.ex:1-3` defines `Alethea.Encryption.Binary` (`use Cloak.Ecto.Binary, vault: Alethea.Encryption.Vault`). Exhaustive grep shows exactly **one** consumer: `lib/alethea/foundation/accounts/bot_config.ex:42,55` (Telegram bot token ciphertext). No patient/clinical schema uses it. CLAUDE.md's "use Cloak.Ecto with the patient's unique derived key" describes intent, not the implementation.

**(b) `Alethea.Encryption.PatientVault` — the real patient mechanism.** `lib/alethea/encryption/patient_vault.ex:1-51`:
- `encrypt(plaintext, key)` / `decrypt(binary, key)`, 32-byte key enforced by guard.
- AES-256-GCM, 12-byte random IV, AAD `"alethea-patient-data"`, 16-byte tag.
- Wire format: `[IV 12][ciphertext][tag 16]`.
- Returns `{:ok, binary}` / `{:error, :invalid_key_size | :empty_plaintext | :encryption_failed | :decryption_failed}`.

**Key storage and derivation** — `lib/alethea/accounts/encryption_key.ex:7-26`: table `encryption_keys`, `binary_id` PK, fields `encrypted_key :binary`, `type :string`, `version :integer default 1`, `patient_id :binary_id`, `belongs_to :professional`. `type` is validated to `["patient", "professional", "patient_clinical_record"]`.

Key ladder in `lib/alethea/accounts.ex`:
- `load_professional_kek/1` (:117-119) → `ProfessionalKek.load_kek/1`.
- `load_patient_dek/2` (:121-129) → `Repo.get_by(EncryptionKey, patient_id:, type: "patient")` then `PatientVault.decrypt(key_record.encrypted_key, professional_kek)`.
- `ensure_clinical_record_dek/2` (:249-274) → lazily provisions the `"patient_clinical_record"` key: `:crypto.strong_rand_bytes(32)` wrapped with the KEK, inserted `on_conflict: :nothing` against the partial unique index `(patient_id, type) WHERE patient_id IS NOT NULL`.
- `destroy_clinical_record_dek/1` (:286-294) → **cryptographic deletion**: `delete_all` of the `"patient_clinical_record"` key row, returning `{:ok, :destroyed | :absent}`.

**Dual-key seam.** `lib/alethea/clinical_record.ex:47-56` documents `@type keyring :: %{patient_dek: binary(), clinical_record_dek: binary()}`; `:348-350` `dek_for/2` picks the DEK from the **row's own** `encryption_version` (1 = shared patient DEK, 2 = CR-scoped DEK). New ClinicalRecord writes stamp `2` (`clinical_record.ex:1430`).

**Column convention** (identical across `ClinicalNote`, `TargetBehavior`, `ConsultationEvidence`, `ClinicianObservation`, `AIProposal`, `FunctionalAnalysisDraft`, `Rag.Chunk`):
- `field :encrypted_<name>, :binary`
- `field :encryption_version, :integer, default: 1`
- `field :<name>, :string, virtual: true, redact: true`
- `@derive {Inspect, except: [:<name>]}`
- plaintext is **never** in `cast/2` — only the ciphertext is castable. See `lib/alethea/clinical_record/functional_analysis_draft.ex:29-60` and `lib/alethea/clinical_record/rag/chunk.ex:42-105`.

### 2. Encrypted structured payload precedent

`lib/alethea/clinical_record/functional_analysis_content.ex:15-121` is the exact precedent and it is **not** an Ecto type:
- Plain Elixir struct with 12 string fields (`defstruct`, `@type t`).
- `serialize/1` (:66-73) → `@sentinel <> Jason.encode!([@format, @version, ordered_fields])` where `@sentinel = "ALETHEA_FUNCTIONAL_ANALYSIS_CONTENT\n"`, `@format = "alethea.functional-analysis-content"`, `@version = 1`, and `ordered_fields` is a positional list of `[name, value]` pairs (deterministic ordering).
- `parse/1` (:83-98) → `{:structured, t}` or `{:legacy, t}`; any envelope that does not match completely is preserved byte-for-byte as legacy text.
- The serialized string is the plaintext that `ClinicalRecord.upsert_functional_analysis_content/4` (`clinical_record.ex:1135-1162`) feeds into `persist_functional_analysis_draft/5`, which encrypts it into the single `encrypted_body :binary`.

Conclusion: **no precedent exists for layering `Ecto.Type` over `Cloak.Ecto.Binary`**, and the codebase deliberately keeps encryption in the context, not in the schema. A speech-span list should follow this same "canonical serialize → `PatientVault.encrypt/2` → one `:binary` column" route.

### 3. Patient / professional scoping and strict authorization

`lib/alethea/accounts/patient.ex:5-25`: `@primary_key {:id, :binary_id, autogenerate: true}`, `@foreign_key_type :binary_id`, `belongs_to :professional`, `field :status, :string, default: "active"`.

`lib/alethea/accounts.ex:163-169` — the authorization primitive:
```elixir
def get_patient_for_professional(professional_id, patient_id) do
  Patient
  |> where([p], p.id == ^patient_id)
  |> where([p], p.professional_id == ^professional_id)
  |> where([p], p.status != "deleted")
  |> Repo.one()
end
```

Authorization is **in the context**, not in a web plug. Every public `ClinicalRecord` function takes `%Professional{}` as the first argument:
- Direct form: `create_target_behavior/3` (`clinical_record.ex:74-86`), `create_clinical_note/3` (:106-118), `list_clinical_notes/2` (:130-151) — `case get_patient_for_professional(...) do nil -> deny_access(...); patient -> with {:ok, kek} <- load_professional_kek, {:ok, dek} <- load_patient_dek ... end`.
- Extracted form: `with_patient/3` (:252-264) runs the auth → KEK → patient DEK → CR DEK ladder and invokes `fun.(patient, keyring)`; `with_target_behavior/4` (:303-311) adds the child-ownership check.
- Denials: `deny_access/2` (:1471-1474) writes a **content-free** audit row via `Audit.log_denied/3` and returns `{:error, :unauthorized}`. A malformed UUID is normalized to `nil` before auditing (:313-331) so it is never echoed.
- `Alethea.ClinicalRecord.Audit` (`lib/alethea/clinical_record/audit.ex:21-31`) is a closed vocabulary: `@actions`, `@resource_types`, `@outcomes`; `details` is machine-built from `outcome` only, never caller-supplied.

Write path shape — `persist_functional_analysis_draft/5` (`clinical_record.ex:1419-1458`): `PatientVault.encrypt(body, keyring.clinical_record_dek)` → `Ecto.Multi` with `:record` (insert, `on_conflict: {:replace, [...]}`), `:audit` (`Audit.changeset/1`), `:outbox_event` (`Oban.insert/3` with `Outbox.event/2`) → `Repo.transaction()` → `finalize_record_multi/1`.

### 4. Audio duration metadata — greenfield, but with an existing contract

`lib/alethea/ai/whisper.ex:46-63` already defines the exact span shape:
```elixir
@type segment :: %{start: number(), end: number(), text: String.t()}
@type transcription :: %{text: String.t(), segments: [segment()], language: String.t() | nil}
@callback transcribe(audio :: binary() | String.t(), opts :: keyword()) :: {:ok, transcription()} | {:error, term()}
```
- **No `speaker` field** — #317 adds speaker attribution on top of this shape.
- **No `duration`** anywhere in the behaviour or adapters.
- `lib/alethea/ai/whisper/fake.ex` returns `%{text: "", segments: [], language: nil}`; wired via `config :alethea, :ai_whisper, Alethea.AI.Whisper.Fake` (`config/test.exs:96`), dispatched through `Alethea.AI.whisper/0`.
- Production adapter `Alethea.AI.Whisper.Groq` is explicitly out of scope (`ai-whisper-groq-foundation` change), and the storage wiring is deferred to a future `grabacion-transcripcion-foundation` change (`whisper.ex:31-44`).
- No upload path, no storage adapter, no audio schema, no Oban audio worker exists.
- `openspec/UBIQUITOUS_LANGUAGE.md:35-42` defines *Sesión clínica* (happens outside the system; system stores the recording + transcript), *Grabación* (audio, transcribed by Whisper), *Transcripción* (text, enters the patient's RAG).

### 5. Enum modeling

**`Ecto.Enum` appears zero times in `lib/`.** The convention is `:string` + `validate_inclusion` against a `~w(...)` module attribute, mirrored by a DB CHECK constraint:
- `lib/alethea/clinical_record/consultation_evidence.ex:34,79` — `@source_kinds ~w(clinical_note message)` + `validate_inclusion(:source_kind, @source_kinds)`.
- `priv/repo/migrations/20260831213217_create_consultation_evidences.exs:51-53` — `create constraint(:consultation_evidences, :source_kind_must_be_valid, check: "source_kind IN ('clinical_note', 'message')")`.
- Same pairing for `ai_proposals.status` (migration `20260831215154:39-41`) and `messages.behavior_type` (`20260526125520:10-12`, widened in `20260622000001:41-43`).

Note: the issue writes the speaker enum as `:patient | :therapist` (atoms). The codebase convention would store `"patient" | "therapist"` strings. Because the speaker lives **inside the encrypted JSON payload**, a DB CHECK constraint cannot enforce it — validation must happen in the serializer/parser module.

### 6. Where the schema should live

- `lib/alethea/clinical_record/` holds professional-authored, patient+professional-scoped, DEK-encrypted clinical artifacts (`clinical_note.ex`, `target_behavior.ex`, `consultation_evidence.ex`, `clinician_observation.ex`, `ai_proposal.ex`, `functional_analysis_draft.ex`, `rag/`). `lib/alethea/clinical/` holds Telegram patient journaling (`message.ex`, `session.ex`, `summary.ex`, `trend.ex`) and has no `professional_id` on its rows (`clinical/outbox.ex:12-15` documents this explicitly). A transcript scoped to *both* patient and professional belongs in `ClinicalRecord`.
- Sibling issue status: #316 landed as `Alethea.AI.Chains.FunctionalAnalysisDraftChain` + `FunctionalAnalysisContent` (commit `a20be30`, `openspec/sdd/eorc-draft-chain-316/`). #315 landed as `lib/alethea/clinical_record/dismissed_evidence_suggestion.ex` + migration `20260923161320` (no SDD dir — direct route). Both used `lib/alethea/clinical_record/`.
- **Name collision**: `clinical_sessions` is already the Telegram journaling session table (`lib/alethea/clinical/session.ex:7`), and `Alethea.Accounts.SessionSchedule` exists. Use table `session_transcripts` and module `Alethea.ClinicalRecord.SessionTranscript`.
- SDD dir convention from #316: `openspec/sdd/{slug}-{issue}/` with files `exploration.md`, `proposal.md`, `spec.md`, `design.md`, `tasks.md`.

### 7. Migration conventions

From `20260828042231_create_clinical_notes.exs`, `20260831215155_create_functional_analysis_drafts.exs`, `20260923161320_create_dismissed_evidence_suggestions.exs`:
```elixir
create table(:x, primary_key: false) do
  add :id, :binary_id, primary_key: true
  add :encrypted_body, :binary, null: false
  add :encryption_version, :integer, null: false, default: 1
  add :patient_id, references(:patients, on_delete: :delete_all, type: :binary_id), null: false
  add :professional_id, references(:professionals, on_delete: :restrict, type: :binary_id), null: false
  timestamps(type: :utc_datetime)          # or timestamps(type: :utc_datetime, updated_at: false) for immutable rows
end
create index(:x, [:patient_id])
```
- Patients cascade (`:delete_all`); professionals are restricted (`:restrict`) because they authored clinical decisions.
- Domain timestamps that need sub-second precision use `:utc_datetime_usec` (`consultation_evidences.occurred_at`, `dismissed_evidence_suggestions.dismissed_at`); row `timestamps` stay `:utc_datetime`.
- Immutability, when required, is enforced by a `BEFORE UPDATE` plpgsql trigger plus `def up`/`def down` instead of `change` (`create_clinical_notes.exs:16-56`).
- Composite FKs via raw `execute/2` when a child must belong to the same patient (`create_dismissed_evidence_suggestions.exs:32-44`).

### 8. Downstream registries that know about each ClinicalRecord table

Adding a new table means deciding, explicitly, whether it registers in each of these:
- `lib/alethea/clinical_record/retention.ex:55-62` — `@tables` list (schema, resource_type literal, retention timestamp field). Drives eligibility sweeps, tombstones, and the terminal crypto-erasure that fires only when **all** registered tables reach zero rows for the patient (`:296-330`). **If `session_transcripts` is not registered, `destroy_clinical_record_dek/1` could fire while transcript rows still exist, leaving undecryptable rows.**
- `lib/alethea/clinical_record/outbox.ex:49-54` — `resource_type/1` dispatch (`@allowed_args` is identifier-only, so ciphertext can never leak into `oban_jobs.args`).
- `lib/alethea/clinical_record/audit.ex:21-31` — `@actions` / `@resource_types` closed vocabularies.
- `lib/alethea/clinical_record/rag/indexer.ex:417-474` — `fetch_and_decrypt/5` clauses per resource kind; `Rag.Chunk.source_resource_type` is a free `:string` with no FK.

## Approaches compared

**Fork A — how to store speech spans**

| # | Approach | Pros | Cons | Effort |
|---|---|---|---|---|
| A1 | Single `encrypted_spans :binary` blob: a `SessionTranscriptContent` module serializes `[%{start, end, text, speaker}]` to sentinel + versioned JSON, encrypted once | Matches the acceptance criterion's literal "encrypted JSON payload"; mirrors `FunctionalAnalysisContent` exactly; one crypto op per transcript; cryptographic deletion is one row; no span text ever reaches a queryable column | Cannot query/filter by span in SQL; whole transcript must be decrypted to read one span; envelope versioning must be hand-rolled | Low |
| A2 | Separate `session_transcript_spans` table, one row per span with its own `encrypted_text` | Span-level indexing, ordering, and future per-span RAG chunking; span timestamps queryable in SQL | N crypto ops per transcript; plaintext-visible `speaker` column leaks who spoke when; a second table to register in Retention/Outbox/Audit; contradicts "encrypted JSON payload" in the criteria | High |
| A3 | Custom `Ecto.Type` for the span list layered over `Cloak.Ecto.Binary` | Transparent encrypt/decrypt at the schema boundary | **No precedent** — Cloak is vault-wide-keyed and cannot see the per-patient DEK; the DEK is only resolvable in the context after the KEK ladder. Architecturally impossible without rewriting the key model | High / not viable |

**Fork B — module placement**

| # | Approach | Pros | Cons | Effort |
|---|---|---|---|---|
| B1 | `Alethea.ClinicalRecord.SessionTranscript`, table `session_transcripts` | Patient+professional scoping, DEK v2, retention/audit/outbox/RAG machinery all already exist here; matches #315/#316 placement | Adds a 7th table to the Retention registry (must be done deliberately) | Low |
| B2 | `Alethea.Clinical.SessionTranscript` | Sits next to `Clinical.Session`; "session" naming reads naturally | `Alethea.Clinical` rows carry no `professional_id` by design; would need a parallel auth/audit/retention stack; collides conceptually with the journaling session | Medium |

**Fork C — audio duration metadata sensitivity**

| # | Approach | Pros | Cons |
|---|---|---|---|
| C1 | `audio_duration_seconds :integer` as plaintext column | Queryable; simple; duration alone is weak PII | CLAUDE.md lists "audio metadata" among things that must be encrypted — needs an explicit, documented decision |
| C2 | Duration folded into the encrypted payload envelope | Strictly satisfies the CLAUDE.md mandate | Not queryable; cannot compute aggregate session-time reports without decrypting every row |

## Recommendation

**A1 + B1 + C1 (with C1 documented as an explicit decision).**

Concretely:
- `lib/alethea/clinical_record/session_transcript.ex` — `Alethea.ClinicalRecord.SessionTranscript`, `binary_id` PK, `belongs_to :patient` / `belongs_to :professional`, `field :encrypted_spans, :binary`, `field :encryption_version, :integer, default: 1` (stamped `2` on write), `field :spans, {:array, :map}, virtual: true, redact: true`, `@derive {Inspect, except: [:spans]}`, `field :audio_duration_seconds, :integer`, `field :recorded_at, :utc_datetime_usec`, `timestamps(type: :utc_datetime)`. Plaintext not castable.
- `lib/alethea/clinical_record/session_transcript_content.ex` — struct + `new/1`, `serialize/1`, `parse/1` mirroring `FunctionalAnalysisContent`: sentinel `"ALETHEA_SESSION_TRANSCRIPT_SPANS\n"`, format `"alethea.session-transcript-spans"`, version `1`, payload a positional JSON array of `[start, end, speaker, text]`. Speaker validated against `~w(patient therapist)` here (a DB CHECK cannot reach inside ciphertext). Reuse the Whisper `segment` field names `start`/`end` so the future Groq adapter maps 1:1.
- Migration `create_session_transcripts` following the conventions above; index on `[:patient_id]` and `[:patient_id, :recorded_at]`.
- Context functions on `Alethea.ClinicalRecord`, both routed through `with_patient/3`: `create_session_transcript(professional, patient_id, attrs)` (encrypt → `Ecto.Multi` record + `Audit` + `Outbox` event) and `get_session_transcript/3` + `list_session_transcripts/2` (decrypt via `dek_for/2` + `decrypt_or_placeholder/2`).
- New literals: `Audit.@actions` gains `session_transcript_created`; `@resource_types` gains `session_transcript`; `Outbox.resource_type/1` gains a `%SessionTranscript{}` clause.
- **Retention registration is a scope decision for the proposal**: registering `{SessionTranscript, "session_transcript", :inserted_at}` in `Retention.@tables` is correct but drags in tombstone/RAG-purge behavior. If deferred to a follow-up PR, that must be stated explicitly as a known gap, not left silent.

## Affected areas

- `lib/alethea/clinical_record/session_transcript.ex` — new schema.
- `lib/alethea/clinical_record/session_transcript_content.ex` — new serializer/parser.
- `priv/repo/migrations/<ts>_create_session_transcripts.exs` — new table.
- `lib/alethea/clinical_record.ex` — new public context functions (create/get/list) + private persist/decrypt helpers.
- `lib/alethea/clinical_record/audit.ex:21-31` — extend `@actions` and `@resource_types`.
- `lib/alethea/clinical_record/outbox.ex:49-54` — new `resource_type/1` clause (+ alias).
- `lib/alethea/clinical_record/retention.ex:55-62` — `@tables` registration (or an explicit deferral note).
- `lib/alethea/clinical_record/rag/indexer.ex:417-474` — a `fetch_and_decrypt/5` clause if transcripts should enter the RAG (ADR-003 says they should, eventually).
- `test/alethea/clinical_record/` — new schema/context tests; `test/alethea/clinical_record_test.exs` for the authorization matrix.
- Untouched: `lib/alethea/ai/whisper*.ex` (behaviour is already sufficient); `lib/alethea_web/` (no UI in scope).

## Risks

1. **Cryptographic-deletion hole.** If `session_transcripts` is not added to `Retention.@tables`, `maybe_destroy_key/3` (`retention.ex:296-320`) can destroy the CR DEK at "zero remaining rows" while transcript rows still exist — permanently undecryptable data with no tombstone and no audit trail. This is the single highest-severity risk.
2. **Speaker enum cannot be DB-enforced.** Because the speaker lives inside ciphertext, the codebase's standard `create constraint(..., check: ...)` guard is unavailable. Validation must be in `SessionTranscriptContent` and covered by tests, or bad speaker values silently round-trip.
3. **CLAUDE.md vs. reality on Cloak.** The mandate says "use `Cloak.Ecto` with the patient's unique derived key"; the implementation is `PatientVault` + manual DEK. A naive implementation following CLAUDE.md literally would encrypt transcripts under the **vault-wide** key, breaking per-patient cryptographic deletion. The proposal should call this out.
4. **`start`/`end` are reserved-ish in Elixir/JSON.** `end` is an Elixir keyword; `%{end: x}` is legal but `map.end` parses awkwardly. The Whisper behaviour already uses `end`, so consistency wins — but the serializer should use positional arrays (as `FunctionalAnalysisContent` does) rather than string-keyed maps to sidestep it.
5. **`audio_duration_seconds` plaintext** is a documented deviation from CLAUDE.md's "audio metadata must be encrypted". Needs an explicit accepted decision or it will surface in review.
6. **Naming.** `clinical_sessions` is taken; a `SessionTranscript` under `ClinicalRecord` while `Clinical.Session` means something entirely different is a real comprehension hazard. Mirror the `Alethea.Clinical` / `Alethea.ClinicalRecord` boundary moduledoc (`clinical_record.ex:6-11`) in the new module's docs.
7. **Ingestion source undefined.** #317 only persists; nothing produces spans yet (no Groq adapter, no upload path, no speaker diarization). Tests must construct spans directly, and the proposal should state that the producer is out of scope.

## Key learnings

1. Alethea encrypts patient clinical data with manual AES-256-GCM envelope crypto via `Alethea.Encryption.PatientVault`, not with `Cloak.Ecto` field types, which are used only for the Telegram bot token.
2. Encrypted structured payloads in this codebase serialize to a sentinel-prefixed versioned JSON string first and are then encrypted into a single `:binary` column, with no `Ecto.Type` layering anywhere.
3. Strict access authorization already lives inside context functions through `Accounts.get_patient_for_professional/2` followed by the professional-KEK to patient-DEK ladder, writing content-free denial audit rows on failure.
4. The `Alethea.AI.Whisper` behaviour already declares the exact `%{start, end, text}` span shape but has no speaker field, no duration, and no persistence layer at all.
5. Omitting a new encrypted table from `Retention.@tables` would let the terminal crypto-erasure destroy the clinical-record DEK while rows still exist, permanently orphaning that ciphertext.
