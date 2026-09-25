# Proposal: SessionTranscript schema and persistence with speaker attribution (#317)

**Status:** decided — D1-D4 locked by the user (all recommended defaults) · **Parent:** #314 · **Unblocks:** #320, #328

## Intent

Whisper emits `%{start, end, text}` segments (`lib/alethea/ai/whisper.ex:46-63`) but nothing persists them and nothing records *who spoke*. Without speaker-attributed, timestamped, patient-encrypted transcripts, the RAG projection cannot index sessions (#320) and the Workbench cannot cite audio evidence (#328). This issue builds the storage seam only.

## Scope

### In Scope
- Migration + `Alethea.ClinicalRecord.SessionTranscript` (table `session_transcripts`), scoped to patient **and** professional.
- `SessionTranscriptContent`: sentinel + versioned positional JSON array of `[start, end, speaker, text]`; speaker validated in-module against `~w(patient therapist)`.
- One `encrypted_spans :binary` blob under the clinical-record DEK, `encryption_version` = 2.
- Context create/fetch via `with_patient/3` (auth → KEK → DEK), content-free `deny_access/2` on failure.
- Outbox event on creation (the seam #320 consumes) + `Audit` and `Outbox.resource_type/1` literals.

### Out of Scope
- Audio capture/upload/storage, Groq adapter, diarization (no producer exists; tests build spans directly).
- RAG chunking (#320), draft button (#319), citation UI (#328), any `lib/alethea_web/` change.

## Capabilities

### New Capabilities
- `session-transcript-persistence`: encrypted, speaker-attributed transcript storage with authorized create/fetch.

### Modified Capabilities
- None (`openspec/specs/` absent; repo uses `openspec/sdd/{slug}-{issue}/`).

## Approach

Exploration fork **A1 + B1**. Mirrors `functional_analysis_content.ex` exactly: canonical serialize → `PatientVault.encrypt/2` → one `:binary` column; write path is `Ecto.Multi` record + audit + outbox, as in `persist_functional_analysis_draft/5`.

Rejected: per-span table (leaks speaker in plaintext columns, contradicts the "encrypted JSON payload" criterion); `Ecto.Type` over `Cloak.Ecto` (impossible — Cloak is vault-wide-keyed, cannot see the per-patient DEK).

**CLAUDE.md note:** CLAUDE.md's "use `Cloak.Ecto` with the patient's derived key" is aspirational. The real mechanism is `Alethea.Encryption.PatientVault`; Cloak's only consumer is the Telegram bot token. Following CLAUDE.md literally would encrypt under the vault-wide key and break per-patient cryptographic deletion. Not a violation.

## Locked decisions

| # | Decision | Basis |
|---|---|---|
| L1 | Module `ClinicalRecord.SessionTranscript`, table `session_transcripts` | `clinical_sessions` taken; `Alethea.Clinical` rows carry no `professional_id` |
| L2 | Single encrypted blob, no per-span table | AC wording + `FunctionalAnalysisContent` precedent |
| L3 | Speaker as `"patient"`/`"therapist"` strings validated in the serializer | `Ecto.Enum` unused; CHECK cannot reach ciphertext |
| L4 | Span names `start`/`end`, positional JSON array | 1:1 with the Whisper contract; sidesteps Elixir's `end` keyword |
| L5 | Outbox event on create; RAG indexing not implemented here | #320 AC1 consumes this event |
| L6 | `binary_id` PK, patient FK `:delete_all`, professional FK `:restrict`, `timestamps(type: :utc_datetime)` | 3 recent migrations |

## Decisions D1-D4 (locked by user)

All four confirmed with the recommended default.

| # | Decision | Chosen |
|---|---|---|
| D1 | `audio_duration_seconds` storage | **(a) plaintext column** — weak PII, enables session-time reporting without decryption; recorded as an accepted deviation from CLAUDE.md's "audio metadata" mandate |
| D2 | `Retention.@tables` registration | **(a) register now** — closes the crypto-erasure hole; adds one `@tables` entry + `Audit`/`Tombstone` vocabulary + tests |
| D3 | `recorded_at` nullability | **(a) required, non-null** — therapist always knows the session date at creation; avoids a later migration |
| D4 | Context API surface | **(a) create + get only** — AC says "persist and fetch" (singular); #320 resolves by id from the outbox event; no `list_session_transcripts/2` in this PR |

No collisions: `create_session_transcript/3`, `get_session_transcript/3` are both absent from `ClinicalRecord`'s current public API.

## Affected Areas

| Area | Impact | Description |
|------|--------|-------------|
| `lib/alethea/clinical_record/session_transcript.ex` | New | Schema |
| `lib/alethea/clinical_record/session_transcript_content.ex` | New | Serializer/parser + speaker validation |
| `priv/repo/migrations/<ts>_create_session_transcripts.exs` | New | Table + indexes |
| `lib/alethea/clinical_record.ex` | Modified | Public create/fetch + persist/decrypt helpers |
| `lib/alethea/clinical_record/audit.ex:21-31` | Modified | `@actions` / `@resource_types` |
| `lib/alethea/clinical_record/outbox.ex:49-54` | Modified | `resource_type/1` clause |
| `lib/alethea/clinical_record/retention.ex:55-62` | Modified | `@tables` entry (D2: register now) |
| `test/alethea/clinical_record/` | New | Schema, serializer, authorization-matrix tests |

## Risks

| Risk | Likelihood | Mitigation |
|------|------------|------------|
| Crypto-erasure orphans transcripts (Retention gap) | Med | D2 = register now, else document as accepted gap |
| Bad speaker values round-trip silently (no DB CHECK) | Med | Validate in `SessionTranscriptContent`; reject at write |
| Reviewer flags `PatientVault` as a CLAUDE.md violation | High | Stated in Approach |
| `SessionTranscript` vs `Clinical.Session` comprehension hazard | Med | Mirror the `Clinical`/`ClinicalRecord` boundary moduledoc |
| No producer → untested against real Whisper output | Med | Reuse Whisper's `start`/`end` names so the adapter maps 1:1 |

## Rollback Plan

Single additive PR. Revert = `mix ecto.rollback` one step (drops `session_transcripts`; patient/professional rows untouched) + revert the commit. `Audit`/`Outbox`/`Retention` edits are additive list entries; removing them cannot orphan rows because no transcripts exist beforehand.

## Dependencies

None blocking. #315/#316 landed; #320 and #328 depend on this.

## Success Criteria

- [ ] A transcript with patient and therapist spans round-trips create → fetch with order, timestamps, and speakers intact.
- [ ] No span text or speaker in any plaintext column or in `oban_jobs.args`; blob unreadable without the clinical-record DEK.
- [ ] Cross-professional fetch returns `{:error, :unauthorized}` + a content-free audit row.
- [ ] An invalid speaker value is rejected at write time.
- [ ] Creation enqueues exactly one identifier-only outbox event.
- [ ] `mix precommit` passes.
