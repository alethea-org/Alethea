# Tasks: SessionTranscript schema and persistence with speaker attribution (#317)

## Review Workload Forecast

| Field | Value |
|---|---|
| Estimated changed lines | PR1 ~405 / PR2 ~395 / Total ~800 |
| 400-line budget risk | PR1: Medium (~1% over before trim) · PR2: Low |
| Chained PRs recommended | Yes |
| Suggested split | PR1 (base: `main`) → PR2 (base: PR1 branch) |
| Delivery strategy | ask-on-risk (resolved: feature-branch-chain) |
| Chain strategy | feature-branch-chain |
| Branches | `feat/317-session-transcript` → `feat/317-session-transcript-pr2` |

Decision needed before apply: No
Chained PRs recommended: Yes
Chain strategy: feature-branch-chain
400-line budget risk: High

### Suggested Work Units

| Unit | Goal | PR | Focused test command | Harness | Rollback boundary |
|---|---|---|---|---|---|
| 1 | Storage primitives: migration + schema + content module + 2 unit test files | PR1 (base: `main`) | `mix test test/alethea/clinical_record/session_transcript_content_test.exs test/alethea/clinical_record/session_transcript_test.exs` | N/A — no producer, no shipped caller (#319/#320 out of scope) | `mix ecto.rollback` one step + revert 5 files; table is unreferenced |
| 2 | Context API + registry vocabularies + integration/retention tests | PR2 (base: PR1 branch) | `mix test test/alethea/clinical_record_test.exs test/alethea/clinical_record/retention_test.exs` | N/A — server-side only, no UI path | revert 6 files; PR1's table stays dormant and safe |

---

## PR1 — Storage primitives (base: `main`, branch `feat/317-session-transcript`)

### Phase 1 — Migration

- [x] 1.1 `mix ecto.gen.migration create_session_transcripts` (never hand-author the file).
- [x] 1.2 Write the body verbatim per design "Migration": `primary_key: false` + `add :id, :binary_id, primary_key: true`; `encrypted_spans :binary null: false`; `encryption_version :integer null: false, default: 2` (AD3); `audio_duration_seconds :integer` nullable (AD4); `recorded_at :utc_datetime_usec null: false` (D3); `patient_id` FK `on_delete: :delete_all`; `professional_id` FK `on_delete: :restrict` (L6); `timestamps(type: :utc_datetime)`. Keep the four design comments.
- [x] 1.3 Create ONLY `index(:session_transcripts, [:patient_id, :recorded_at])` — no standalone `[:patient_id]` (AD7). No `create constraint(...)`, no immutability trigger, use `change`.
- [x] 1.4 Run `mix ecto.migrate` → `mix ecto.rollback` → `mix ecto.migrate` to prove reversibility.

### Phase 2 — `SessionTranscriptContent` (strict TDD)

- [x] 2.1 RED `test/alethea/clinical_record/session_transcript_content_test.exs`: `new/1` accepts spans mixing `"patient"` and `"therapist"`; `speakers/0 == ~w(patient therapist)`.
- [x] 2.2 RED **table-driven rejection** (trim lever: one module attribute + `for` comprehension, ~−25 lines): `"psychologist"` / `"Patient"` / `:patient` atom / `nil` → `:invalid_speaker`; `[]` → `:empty_transcript`; non-number `start`, `start > end`, non-binary `text`, missing key, extra key → `:invalid_span`.
- [x] 2.3 RED: one bad span at position 40 of 41 rejects the WHOLE list (AD1, no partial write).
- [x] 2.4 RED: `serialize/1` emits `"ALETHEA_SESSION_TRANSCRIPT_SPANS\n"` then exactly `["alethea.session-transcript-spans", 1, [[s, e, spk, txt], …]]`.
- [x] 2.5 RED: `serialize |> parse` round-trips order (never re-sorted), float timestamps, speakers, Unicode/emoji/newline text byte-for-byte; overlapping spans accepted.
- [x] 2.6 RED **table-driven `parse/1` malformed** (trim lever: collapse "wrong format" + "wrong version" into ONE row, ~−10 lines): missing sentinel, wrong format/version, non-JSON, object-instead-of-array, 3-element span, bad speaker → `{:error, :malformed}`, never raises.
- [x] 2.7 GREEN `lib/alethea/clinical_record/session_transcript_content.ex`: `@sentinel`/`@format`/`@version`/`@speakers`, `@enforce_keys [:spans]`, `defstruct spans: []`, `@type speaker/span/t/error`, and `new/1` (`{:ok, t} | {:error, error}`), total `serialize/1`, total `parse/1` (`{:ok, t} | {:error, :malformed}`, no `{:legacy, _}` branch), `speakers/0`. Spans are plain maps (AD8).

### Phase 3 — `SessionTranscript` schema (strict TDD)

- [x] 3.1 RED `test/alethea/clinical_record/session_transcript_test.exs`: `changeset/2` requires `encrypted_spans`, `recorded_at`, `patient_id`, `professional_id`; `audio_duration_seconds` optional and castable.
- [x] 3.2 RED: passing `spans:` leaves `:spans` absent from `changes` (plaintext not castable); `encryption_version` defaults to `2` without being passed (AD3); `inspect/1` on a struct with populated `:spans` contains no span text.
- [x] 3.3 GREEN `lib/alethea/clinical_record/session_transcript.ex` per the design contract: moduledoc with the `Alethea.Clinical.Session` boundary note + the D1 plaintext-duration deviation; `@primary_key {:id, :binary_id, autogenerate: true}`, `@foreign_key_type :binary_id`, `@derive {Inspect, except: [:spans]}`, `field :spans, {:array, :map}, virtual: true, redact: true` (AD5), `belongs_to` patient/professional, `timestamps(type: :utc_datetime)`. No `unique_constraint`, no `update_changeset`.

### Phase 4 — PR1 verification

- [x] 4.1 Run the Unit 1 focused test command; `mix compile --warnings-as-errors --force`; `mix format --check-formatted`.
- [x] 4.2 **Budget check**: `git diff --stat main` authored lines. If > 400, confirm the 2.2/2.6 trim levers are applied; only then flag `size:exception` to the orchestrator. RESULT: 449 lines (both levers applied + extra non-coverage trims); still ~12% over 400 — flagged to orchestrator, no unilateral exception taken.
- [x] 4.3 Confirm the diff touches ONLY the 5 PR1 files — no `clinical_record.ex`, no registry file, no `rag/indexer.ex` (F2), no `lib/alethea_web/**`. Confirmed via `git status --short`.

---

## PR2 — Context + registries (base: `feat/317-session-transcript`, branch `feat/317-session-transcript-pr2`)

**Budget check (mirrors PR1's 4.2 protocol)**: `git diff --stat --cached feat/317-session-transcript` (staged, against the PR1 base branch) authored lines. RESULT: **420 changed lines** (407 insertions + 13 deletions across `clinical_record.ex`, `audit.ex`, `outbox.ex`, `retention.ex`, `tombstone.ex`, `clinical_record_test.exs`, `retention_test.exs`) — ~5% over the 400 budget after applying trim levers not in the original design (merged the authorized/round-trip/no-leak/outbox tests into one, merged the two cross-professional-denial tests into one, merged the two not-found-audit tests into one, dropped a non-required AD6 undecryptable test, simplified the AC2 no-leak check to a single-column ciphertext assertion instead of a full-row loop). Reduced from an initial 547 lines through these trims. Flagged to the orchestrator per the do-not-self-authorize-`size:exception` instruction — no unilateral exception taken; the design's own forecast for this slice (~395) did not account for the full authorization-matrix + crypto-erasure-gating test depth actually required by AC3/7.3.

### Phase 5 — Registry vocabularies

- [x] 5.1 `lib/alethea/clinical_record/audit.ex`: `@actions` += `"session_transcript_created"`; `@resource_types` += `"session_transcript"`.
- [x] 5.2 `lib/alethea/clinical_record/outbox.ex`: alias += `SessionTranscript`; `event/2` `@spec` union + moduledoc list += `SessionTranscript.t()`; add `defp resource_type(%SessionTranscript{}), do: "session_transcript"`.
- [x] 5.3 `lib/alethea/clinical_record/retention.ex` (**F1**): alias += `SessionTranscript`; `@tables` += `{SessionTranscript, "session_transcript", :inserted_at}` next to the `ClinicalNote` entry; add `defp identifiers_for(SessionTranscript, resource_id), do: base_identifiers(SessionTranscript, resource_id)` (the `ClinicalNote`-shaped clause — transcripts have no `target_behavior_id`).
- [x] 5.4 `lib/alethea/clinical_record/tombstone.ex` (**F1**): `@resource_types` += `"session_transcript"`; update the "six" comment to "seven".
- [x] 5.5 Assert `lib/alethea/clinical_record/rag/indexer.ex` stays UNTOUCHED (F2 — the `{:unknown, _} -> :ok` catch-all already absorbs the event; #320 owns that clause).

### Phase 6 — Context API (strict TDD, `test/alethea/clinical_record_test.exs`)

- [x] 6.1 RED round-trip (AC1): create with mixed patient/therapist spans → `get_session_transcript/3` returns every span with order, float timestamps, speaker, text intact.
- [x] 6.2 RED no-leak (AC2): raw SQL `SELECT` shows no span text/speaker in `encrypted_spans`; `oban_jobs.args` has exactly the 5 identifier keys.
- [x] 6.3 RED authorization (AC3): professional B `create`/`get` against A's patient → `{:error, :unauthorized}` + content-free `clinical_record_access_denied` rows with `details == %{"outcome" => "denied"}`; a transcript id from another patient → `{:error, :not_found}` + a denial row typed `"session_transcript"`; a malformed UUID → `{:error, :not_found}` audited with `resource_id: nil`.
- [x] 6.4 RED write rejection (AC4): a bad speaker → `{:error, :invalid_speaker}` AND zero `session_transcripts` rows, zero success audit rows, zero `oban_jobs`.
- [x] 6.5 RED outbox + storage (AC5): exactly one job with `event == "session_transcript_created"`; persisted `encryption_version == 2`; `audio_duration_seconds: nil` accepted and an integer round-trips.
- [x] 6.6 GREEN `lib/alethea/clinical_record.ex`: aliases += `SessionTranscript`, `SessionTranscriptContent`; add `create_session_transcript/3` with the design's `@doc`/`@spec`, wrapping `SessionTranscriptContent.new(Map.fetch!(attrs, :spans))` INSIDE the `with_patient/3` callback (AD2), atom-keyed `attrs` (AD9).
- [x] 6.7 GREEN private `persist_session_transcript/5`: `serialize/1` → `PatientVault.encrypt(body, keyring.clinical_record_dek)` → `Ecto.Multi` `:record` → `:audit` (`action: "session_transcript_created"`, `resource_type: "session_transcript"`, `outcome: "success"`) → `Oban.insert(:outbox_event, Outbox.event("session_transcript_created", record))` → `Repo.transaction()` → `finalize_record_multi()`. Pass `encryption_version: 2` explicitly. No `on_conflict:`/`conflict_target:`.
- [x] 6.8 GREEN `get_session_transcript/3` + private `fetch_owned_session_transcript/3` mirroring `fetch_owned_target_behavior/3` (malformed UUID audited as `nil` via `log_denied_audit(professional.id, audited_id, "session_transcript")`); decrypt via `dek_for(transcript, keyring)` → `parse/1` → `%{transcript | spans: content.spans}`; non-`:not_found` failures map to `{:error, :undecryptable}` (AD6 — never a placeholder, never `spans: []`).

### Phase 7 — Retention (strict TDD, `test/alethea/clinical_record/retention_test.exs`)

- [x] 7.1 RED: `"session_transcript" in Retention.resource_types()`; `eligible_records(SessionTranscript, …)` returns identifiers only (no `encrypted_spans` key).
- [x] 7.2 RED: `legally_delete_record({"session_transcript", id})` inserts a tombstone, an audit row, and a `rag_purge` job — proves both F1 edits (5.3 clause + 5.4 vocabulary).
- [x] 7.3 RED crypto-erasure gating: with every other registered table at zero and one transcript remaining, the `patient_clinical_record` key survives and no `clinical_record_key_destroyed` audit row is written; deleting that transcript then destroys the key exactly once, leaving the shared patient DEK untouched.
- [x] 7.4 GREEN: close any registry gap 7.1–7.3 exposes. (None found — 5.1-5.4 fully covered the three F1 edits on the first pass.)

### Phase 8 — PR2 verification

- [x] 8.1 Run `test/alethea/clinical_record/composite_fk_test.exs` and `hypothesis_policy_test.exs` UNMODIFIED — must stay green (`session_transcripts` is correctly absent from the composite-FK enumeration). RESULT: 103 passed, 0 failures, file bytes unchanged.
- [x] 8.2 Run the Unit 2 focused test command; `mix compile --warnings-as-errors --force`; `mix format --check-formatted`. RESULT: 121 passed (Unit 2 alone) / 224 passed (Unit 2 + 8.1 combined), compile clean, format clean. `mix precommit` (full suite) intentionally NOT run per orchestrator's testing/verification protocol for this batch.
- [x] 8.3 Base check: PR2's GitHub diff must NOT show PR1's files. N/A to verify from this sandbox (no `git push`/PR opened here) — current branch is `feat/317-session-transcript-pr2`, checked out from `feat/317-session-transcript` per orchestrator context; no branch operations performed. Flagged for the orchestrator to confirm at PR-open time.
- [x] 8.4 Spec boundary check: the full diff adds no `lib/alethea_web/**` file, no Whisper/Groq adapter, no `rag/indexer.ex` clause, and no `list_session_transcripts/2` (D4). Confirmed via `git status --short` / diff file list — only the 7 files listed in apply-progress changed.
