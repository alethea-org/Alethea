# Design: SessionTranscript schema and persistence with speaker attribution (#317)

**Inputs:** `proposal.md` (L1–L6, D1–D4 locked), `exploration.md`
**Status:** design complete — 9 architecture decisions, 2 findings the exploration missed, **budget forecast ~795 lines → 2 chained PRs**

---

## Technical Approach

Greenfield additive slice. Exactly the `FunctionalAnalysisContent` → `PatientVault.encrypt/2` → one `:binary`
column route, verified verbatim against
`lib/alethea/clinical_record/functional_analysis_content.ex:66-98` and
`lib/alethea/clinical_record.ex:1419-1458`.

```
caller (#320 / tests)
   │  %{spans: [%{start,end,speaker,text}], recorded_at:, audio_duration_seconds:}
   ▼
ClinicalRecord.create_session_transcript/3
   │
   ├─ with_patient/3            auth → KEK → patient_dek → clinical_record_dek   (clinical_record.ex:252-264)
   │     miss ⇒ deny_access/2 → content-free audit row + {:error, :unauthorized}  (:1471-1474)
   ▼
SessionTranscriptContent.new/1   ← speaker + span validation gate (AC "rejected at write")
   │  {:error, :invalid_speaker} short-circuits BEFORE Ecto.Multi ⇒ zero rows written
   ▼
SessionTranscriptContent.serialize/1   sentinel <> Jason.encode!([format, version, [[s,e,spk,txt], …]])
   ▼
PatientVault.encrypt/2  under keyring.clinical_record_dek        (mirrors :1426)
   ▼
Ecto.Multi: :record → :audit → :outbox_event → Repo.transaction → finalize_record_multi/1
                                    │
                                    ▼  identifier-only args (Outbox.@allowed_args, outbox.ex:20)
                          ClinicalRecordOutboxWorker → Indexer.index_event/1
                                    │
                                    ▼  eligibility("session_transcript_created") = {:unknown, _} ⇒ :ok
                                       (indexer.ex:84, :303-304 — no RAG work; #320 replaces this clause)

get_session_transcript/3: with_patient/3 → Repo.get_by(id, patient_id) → dek_for/2 (:348-350)
                          → PatientVault.decrypt → SessionTranscriptContent.parse/1 → %{t | spans: [...]}
```

---

## Architecture Decisions

### AD1 — validation lives in `new/1`; the struct is the proof of validity

`FunctionalAnalysisContent.new/1` is **total** (coerces non-binary to `""`, never fails) because it consumes
untrusted LiveView form params and has a legacy-preservation contract. #317 has the opposite requirement:
the success criterion *"An invalid speaker value is rejected at write time"*. So `new/1` becomes the
**validating constructor** returning a result tuple, and `serialize/1` stays total over an
already-validated struct. You cannot obtain a `%SessionTranscriptContent{}` without passing the gate.

**Rejected — validate inside `serialize/1`.** Makes the success type of a "serializer" a tuple and leaves a
constructible-but-invalid struct in the type space.
**Rejected — validate in `SessionTranscript.changeset/2`.** The changeset never sees plaintext (the
codebase-universal rule, `functional_analysis_draft.ex:51-58`, `rag/chunk.ex:75-103`); by the time the
changeset runs the spans are ciphertext.
**Rejected — a DB `CHECK` constraint** (the `consultation_evidences.source_kind_must_be_valid` idiom,
`20260831213217_create_consultation_evidences.exs:51-53`). Impossible: the speaker lives inside ciphertext.

**Rejection is whole-transcript, never partial.** One bad speaker in span 40 of 41 rejects the entire
create. There is no partial write: the `with` chain short-circuits *before* `Ecto.Multi.new()`, exactly as
`persist_functional_analysis_draft/5` short-circuits on `PatientVault.encrypt/2` failure
(`clinical_record.ex:1426`) — no record, no audit-success row, no outbox job.

### AD2 — validation runs **inside** the `with_patient/3` callback, after authorization

Grounded in `upsert_functional_analysis_content/4` (`clinical_record.ex:1142-1151`), which calls
`FunctionalAnalysisContent.new/serialize` inside the `with_target_behavior` callback. An unauthorized
professional therefore always receives `{:error, :unauthorized}` regardless of payload shape — payload
validity never becomes a side channel that distinguishes "not your patient" from "bad speaker".

### AD3 — `encryption_version` defaults to **2**, not 1

Every sibling table defaults to `1` in both migration and schema
(`20260828040324_create_target_behaviors.exs:9`, `20260908032040_add_encryption_version_...:20`,
`functional_analysis_draft.ex:36`) because each has pre-#197 rows encrypted under the shared patient DEK.
`session_transcripts` is greenfield: **no v1 row can ever exist**, and every write routes through
`with_patient/3`'s `clinical_record_dek`. A default of `1` would be a latent footgun — any insert that
forgot the explicit stamp would label CR-DEK ciphertext as patient-DEK, and `dek_for/2`
(`clinical_record.ex:349`) would hand back the wrong key, producing a silent, permanent decrypt failure.

Migration `default: 2`, schema `default: 2`, **and** the context still passes `encryption_version: 2`
explicitly (belt-and-braces, mirroring `clinical_record.ex:1430`). `dek_for/2` needs no change.

### AD4 — `audio_duration_seconds` is **nullable**

D3 made `recorded_at` non-null on the basis that "the therapist always knows the session date at creation".
That reasoning does not transfer: duration comes from the audio file, and the proposal puts audio
capture/upload/storage explicitly out of scope — **no producer can supply it in this PR**. `null: false`
would force every #317 test and the future manual-entry path to invent a number. Nullable now; tightenable
later with a `modify` migration once the Groq/upload producer lands. Castable, absent from
`validate_required`.

*(This is a scope refinement of D1, not a reversal: D1 locked the plaintext-column *placement*; nullability
was not part of that decision.)*

### AD5 — the virtual field is `:spans, {:array, :map}`, holding **parsed** spans

`ClinicalNote`/`FunctionalAnalysisDraft` use `:body, :string` and split read-then-parse across two public
functions (`get_functional_analysis_draft/3` at `clinical_record.ex:1185` + `get_functional_analysis_content/3`
at `:1222`). **D4 caps this change at one getter**, so the parse folds into it: `get_session_transcript/3`
returns the struct with `:spans` already parsed. `@derive {Inspect, except: [:spans]}` + `redact: true`
still apply.

### AD6 — decrypt/parse failure returns `{:error, :undecryptable}`, not a placeholder

`decrypt_or_placeholder/2` (`clinical_record.ex:1357-1362`) substitutes `"[Error al descifrar]"` — coherent
for a free-text display field, meaningless for a list. Setting `spans: []` would be *clinically
misleading*: an empty list reads as "the session contained no speech". An explicit error atom is the only
honest answer.

### AD7 — **one** composite index `[:patient_id, :recorded_at]`, no standalone `[:patient_id]`

Sibling tables carry both because their second index leads with a *different* column
(`consultation_evidences`: `[:target_behavior_id, :occurred_at]` + `[:patient_id]`,
`20260831213217:47-48`). Here both would lead with `patient_id`, so the standalone index is strictly
redundant — Postgres serves patient-only lookups (`Retention.all_resource_refs/1` at `retention.ex:226-233`,
`remaining_records_count/2` at `:322-330`, and the `patients` FK cascade) from the composite prefix.
`Retention.eligible_records/2` orders by `inserted_at` with no patient filter, so neither index serves it.
`get_session_transcript/3` hits the PK. **Reviewer-vetoable: adding the redundant index back is one line.**

### AD8 — spans are plain maps, not a nested `Span` struct

CLAUDE.md forbids nesting two modules in one file, and a separate `session_transcript_span.ex` for a
four-key map is not worth a module. Plain maps also reproduce the `Alethea.AI.Whisper`
`@type segment :: %{start: number(), end: number(), text: String.t()}` contract (`whisper.ex:46`) verbatim
plus `:speaker`, so the future Groq adapter maps 1:1 (L4).

### AD9 — `attrs` is atom-keyed

`upsert_functional_analysis_content/4` takes string-keyed params because its caller is a LiveView form.
#317's only callers are server-side (#320, tests), so atom keys are correct and avoid
`String.to_atom/1`-adjacent handling of untrusted keys.

---

## Findings the exploration missed (both are correctness bugs if omitted)

**F1 — `Retention.@tables` registration is not one line; it is three edits.**
`run_deletion_multi/5` (`retention.ex:250-261`) inserts a `Tombstone.changeset/2` whose `resource_type` is
`validate_inclusion`-checked against `Tombstone.@resource_types` (`tombstone.ex:20-21`, currently the six
literals). And `legally_delete_record/2` calls `identifiers_for/2` (`retention.ex:358-385`), whose clauses
are an **exhaustive match over the six known schemas** — an unregistered schema raises `FunctionClauseError`.
So D2 requires:

1. `Retention.@tables` += `{SessionTranscript, "session_transcript", :inserted_at}`
2. `Retention.identifiers_for/2` += a `base_identifiers/2` clause (transcripts have no `target_behavior_id`,
   so it mirrors the `ClinicalNote` clause at `:365-367`, not the four-schema clause at `:369-385`)
3. `Tombstone.@resource_types` += `session_transcript`

Without (2), legally deleting a transcript crashes. Without (3), it fails the tombstone changeset and rolls
back the whole `Ecto.Multi`.

**F2 — the outbox event is already safely inert.** `Indexer.eligibility/1` has a catch-all
`def eligibility(event) when is_binary(event), do: {:unknown, event}` (`indexer.ex:84`) and `index_event/1`
maps `{:unknown, _}` to `:ok` (`:303-304`). `session_transcript_created` therefore completes the Oban job
without RAG work and without retries. **No `rag/indexer.ex` change is needed in #317** (the exploration
listed it as affected); #320 replaces line 84's fall-through with `{:index, :session_transcript}`.

---

## Interfaces / Contracts

### `lib/alethea/clinical_record/session_transcript.ex` (new)

```elixir
defmodule Alethea.ClinicalRecord.SessionTranscript do
  @moduledoc """
  Encrypted, speaker-attributed transcript of one clinical session
  (sdd/session-transcript-317, GitHub #317).

  **Boundary note**: a `SessionTranscript` is NOT an `Alethea.Clinical.Session`.
  `Alethea.Clinical.Session` (table `clinical_sessions`) is a patient Telegram
  journaling session and carries no `professional_id`. This row belongs to the
  professional-authored clinical record: it is the transcript of a real
  therapy session (openspec/UBIQUITOUS_LANGUAGE.md: *Transcripción*).

  Plaintext is never cast here — the context serializes the spans through
  `Alethea.ClinicalRecord.SessionTranscriptContent` and encrypts them under the
  patient's clinical-record DEK before calling `changeset/2`, exactly as
  `Alethea.ClinicalRecord.FunctionalAnalysisDraft` does.

  `audio_duration_seconds` is a deliberate plaintext column (D1): duration alone
  is weak PII and session-time reporting must not require decrypting every row.
  This is a documented, accepted deviation from CLAUDE.md's "audio metadata"
  mandate.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @derive {Inspect, except: [:spans]}
  schema "session_transcripts" do
    field :encrypted_spans, :binary
    # Always 2 — greenfield table, every write uses the CR-scoped DEK (AD3).
    field :encryption_version, :integer, default: 2
    field :spans, {:array, :map}, virtual: true, redact: true

    # Plaintext by design (D1). Nullable until an audio producer exists (AD4).
    field :audio_duration_seconds, :integer
    field :recorded_at, :utc_datetime_usec

    belongs_to :patient, Alethea.Accounts.Patient
    belongs_to :professional, Alethea.Accounts.Professional

    timestamps(type: :utc_datetime)
  end

  @doc """
  Create changeset. `:spans` (plaintext) is intentionally NOT castable —
  only `:encrypted_spans` is, mirroring `FunctionalAnalysisDraft.changeset/2`
  and `Rag.Chunk.changeset/2`. `audio_duration_seconds` is the only optional
  field (AD4).
  """
  def changeset(session_transcript, attrs) do
    session_transcript
    |> cast(attrs, [
      :encrypted_spans,
      :encryption_version,
      :audio_duration_seconds,
      :recorded_at,
      :patient_id,
      :professional_id
    ])
    |> validate_required([:encrypted_spans, :recorded_at, :patient_id, :professional_id])
  end
end
```

No `unique_constraint/2`: unlike `FunctionalAnalysisDraft` (one row per target behavior) and `Rag.Chunk`
(one row per source chunk index), a patient may legitimately have many transcripts, including two recorded
at the same instant. No `update_changeset` — create-only for #317.

### `lib/alethea/clinical_record/session_transcript_content.ex` (new)

```elixir
@sentinel "ALETHEA_SESSION_TRANSCRIPT_SPANS\n"
@format   "alethea.session-transcript-spans"
@version  1
@speakers ~w(patient therapist)

@enforce_keys [:spans]
defstruct spans: []

@type speaker :: String.t()                     # "patient" | "therapist"
@type span :: %{start: number(), end: number(), speaker: speaker(), text: String.t()}
@type t :: %__MODULE__{spans: [span()]}
@type error :: :empty_transcript | :invalid_span | :invalid_speaker

@doc "Validating constructor — the write-time gate (AD1)."
@spec new([map()]) :: {:ok, t()} | {:error, error()}

@doc "Serializes an already-validated struct. Total."
@spec serialize(t()) :: String.t()

@doc "Parses a stored plaintext body. Total; never raises."
@spec parse(binary()) :: {:ok, t()} | {:error, :malformed}

@spec speakers() :: [String.t()]                # ~w(patient therapist), for tests/#320
```

**Wire format** (positional, mirroring `FunctionalAnalysisContent.serialize/1` at
`functional_analysis_content.ex:66-73`; positional arrays sidestep Elixir's `end` keyword — L4):

```
"ALETHEA_SESSION_TRANSCRIPT_SPANS\n" <>
  Jason.encode!(["alethea.session-transcript-spans", 1, [[0.0, 3.2, "patient", "…"], …]])
```

**`new/1` rules**, applied per span in order; the **first** failure rejects the whole list:

| Rule | Error |
|---|---|
| `spans == []` | `:empty_transcript` |
| span is not a map with exactly `:start`, `:end`, `:speaker`, `:text` | `:invalid_span` |
| `start`/`end` not `is_number`, or `start > end` | `:invalid_span` |
| `text` not `is_binary` | `:invalid_span` |
| `speaker not in @speakers` | `:invalid_speaker` |

Span **order is preserved verbatim and never re-sorted**; overlapping spans are accepted (diarized crosstalk
is legitimate). `start > end` is rejected because that is intra-span transposition, not overlap.

**`parse/1` asymmetry with `FunctionalAnalysisContent.parse/1` — deliberate.** FAC has a `{:legacy, t}`
branch because `functional_analysis_drafts` holds pre-envelope plaintext bodies. `session_transcripts` is
greenfield: **no legacy body can exist**, so there is nothing to preserve byte-for-byte and the return type
is `{:ok, t} | {:error, :malformed}`. `parse/1` re-runs the same structural + speaker checks as
defense-in-depth against a corrupt or tampered blob, but it is **not** where the AC is satisfied — anything
already persisted passed `new/1` at write time by construction. `{:error, :malformed}` is a corruption
signal, never a user-facing validation path.

### `lib/alethea/clinical_record.ex` (modify)

```elixir
@doc """
Authorizes via `with_patient/3`, validates and serializes the spans, encrypts
them under the patient's clinical-record DEK, and commits the transcript row,
a content-free audit row, and one identifier-only outbox job in a single
`Ecto.Multi` — all-or-nothing.

An invalid speaker (or malformed span) rejects the WHOLE transcript before the
transaction opens: no row, no audit-success row, no outbox job.
"""
@spec create_session_transcript(Professional.t(), Ecto.UUID.t(), %{
        required(:spans) => [map()],
        required(:recorded_at) => DateTime.t(),
        optional(:audio_duration_seconds) => non_neg_integer() | nil
      }) ::
        {:ok, SessionTranscript.t()}
        | {:error,
           :unauthorized
           | SessionTranscriptContent.error()
           | :empty_plaintext | :invalid_key_size | :encryption_failed
           | Ecto.Changeset.t() | term()}
def create_session_transcript(%Professional{} = professional, patient_id, attrs)
    when is_map(attrs) do
  with_patient(professional, patient_id, fn patient, keyring ->
    with {:ok, content} <- SessionTranscriptContent.new(Map.fetch!(attrs, :spans)) do
      persist_session_transcript(professional, patient, content, attrs, keyring)
    end
  end)
end

@doc """
Loads one transcript authorized by `(professional, patient_id, transcript_id)`,
with `:spans` decrypted and parsed. The row is fetched scoped by the authorized
patient's id, so a transcript belonging to another patient — or a malformed id —
yields `{:error, :not_found}` and never reveals whether that id exists elsewhere.
A cross-patient attempt writes a content-free denial audit row.
"""
@spec get_session_transcript(Professional.t(), Ecto.UUID.t(), Ecto.UUID.t()) ::
        {:ok, SessionTranscript.t()}
        | {:error, :unauthorized | :not_found | :undecryptable | term()}
def get_session_transcript(%Professional{} = professional, patient_id, transcript_id) do
  with_patient(professional, patient_id, fn patient, keyring ->
    with {:ok, transcript} <- fetch_owned_session_transcript(professional, patient, transcript_id),
         {:ok, plaintext} <-
           PatientVault.decrypt(transcript.encrypted_spans, dek_for(transcript, keyring)),
         {:ok, content} <- SessionTranscriptContent.parse(plaintext) do
      {:ok, %{transcript | spans: content.spans}}
    else
      {:error, :not_found} -> {:error, :not_found}
      {:error, _reason} -> {:error, :undecryptable}    # AD6
    end
  end)
end
```

`fetch_owned_session_transcript/3` mirrors `fetch_owned_target_behavior/3`
(`clinical_record.ex:313-331`) exactly, including the **malformed-UUID normalization**: an uncastable id is
audited as `nil` so it is never echoed into the audit trail, then `{:error, :not_found}` is returned.
`log_denied_audit(professional.id, audited_id, "session_transcript")`.

```elixir
defp persist_session_transcript(professional, patient, content, attrs, keyring) do
  body = SessionTranscriptContent.serialize(content)

  with {:ok, ciphertext} <- PatientVault.encrypt(body, keyring.clinical_record_dek) do
    changeset =
      SessionTranscript.changeset(%SessionTranscript{}, %{
        encrypted_spans: ciphertext,
        encryption_version: 2,
        audio_duration_seconds: Map.get(attrs, :audio_duration_seconds),
        recorded_at: Map.fetch!(attrs, :recorded_at),
        patient_id: patient.id,
        professional_id: professional.id
      })

    Ecto.Multi.new()
    |> Ecto.Multi.insert(:record, changeset)
    |> Ecto.Multi.insert(:audit, fn %{record: record} ->
      Audit.changeset(%Audit{
        professional_id: professional.id,
        action: "session_transcript_created",
        resource_type: "session_transcript",
        resource_id: record.id,
        outcome: "success"
      })
    end)
    |> Oban.insert(:outbox_event, fn %{record: record} ->
      Outbox.event("session_transcript_created", record)
    end)
    |> Repo.transaction()
    |> finalize_record_multi()
  end
end
```

No `on_conflict:` / `conflict_target:` (unlike `persist_functional_analysis_draft/5` at `:1437-1442`):
transcripts are insert-only, with no single-row cardinality to upsert against.

### `priv/repo/migrations/<timestamp>_create_session_transcripts.exs` (new)

```elixir
defmodule Alethea.Repo.Migrations.CreateSessionTranscripts do
  use Ecto.Migration

  # `session_transcripts` — one encrypted, speaker-attributed transcript per
  # recorded clinical session (sdd/session-transcript-317, GitHub #317).
  # NOT `clinical_sessions`, which is the patient Telegram journaling session.
  def change do
    create table(:session_transcripts, primary_key: false) do
      add :id, :binary_id, primary_key: true

      # Sentinel + versioned positional JSON array of [start, end, speaker, text],
      # encrypted as ONE blob under the patient's clinical-record DEK (L2).
      add :encrypted_spans, :binary, null: false

      # Greenfield table: every write uses the CR-scoped DEK, so 2 — not the
      # sibling tables' 1, which exists only for their pre-#197 rows (AD3).
      add :encryption_version, :integer, null: false, default: 2

      # Plaintext by design (D1) — weak PII, enables session-time reporting
      # without decryption. Nullable: no audio producer exists yet (AD4).
      add :audio_duration_seconds, :integer

      # Required (D3): the therapist always knows the session date at creation.
      add :recorded_at, :utc_datetime_usec, null: false

      add :patient_id, references(:patients, on_delete: :delete_all, type: :binary_id),
        null: false

      # Professionals with authored clinical decisions cannot be hard-deleted,
      # mirroring consultation_evidences, target_behaviors, etc.
      add :professional_id, references(:professionals, on_delete: :restrict, type: :binary_id),
        null: false

      timestamps(type: :utc_datetime)
    end

    # Serves patient-scoped listing (#320) AND, by leading-column prefix, every
    # patient-only scan (Retention sweeps, the patients FK cascade) — so no
    # separate [:patient_id] index is created (AD7).
    create index(:session_transcripts, [:patient_id, :recorded_at])
  end
end
```

`change` (not `up`/`down`): no immutability trigger. Transcripts are not declared immutable in #317 — but
they are also create-only at the context layer, and `timestamps/1` keeps `updated_at` so a future
correction/re-diarization path (#320+) needs no migration. No composite FK (no `target_behavior_id`). No
`create constraint(...)` — the speaker enum lives inside ciphertext (AD1).

### Registry edits

| File | Edit |
|---|---|
| `audit.ex:21-27` | `@actions` += `session_transcript_created` |
| `audit.ex:28-30` | `@resource_types` += `session_transcript` |
| `outbox.ex:9-16` | alias += `SessionTranscript` |
| `outbox.ex:28-36` | `event/2` `@spec` union += `SessionTranscript.t()` (+ moduledoc list) |
| `outbox.ex:49-54` | `defp resource_type(%SessionTranscript{}), do: "session_transcript"` |
| `retention.ex:36-47` | alias += `SessionTranscript` |
| `retention.ex:55-62` | `@tables` += `{SessionTranscript, "session_transcript", :inserted_at}`, placed next to the `ClinicalNote` entry (order-irrelevant: no `target_behavior_id` FK — see the `@tables` moduledoc at `:7-14`) |
| `retention.ex:365-367` | `defp identifiers_for(SessionTranscript, resource_id), do: base_identifiers(SessionTranscript, resource_id)` — **F1, required** |
| `tombstone.ex:20-21` | `@resource_types` += `session_transcript` (comment "six" → "seven") — **F1, required** |
| `rag/indexer.ex` | **Untouched** — F2: the catch-all at `:84` already acknowledges the event |

Retention timestamp field is `:inserted_at`, matching `ConsultationEvidence` (which likewise carries a
domain timestamp, `occurred_at`, yet retains on `inserted_at`, `retention.ex:56`). `recorded_at` is the
*clinical* date, not the last-clinical-action date the BR5 clock measures.

---

## File Changes

| File | Action | Description |
|------|--------|-------------|
| `lib/alethea/clinical_record/session_transcript.ex` | Create | Schema, plaintext not castable |
| `lib/alethea/clinical_record/session_transcript_content.ex` | Create | Validating constructor + serializer/parser |
| `priv/repo/migrations/<ts>_create_session_transcripts.exs` | Create | Table + one composite index |
| `lib/alethea/clinical_record.ex` | Modify | `create_session_transcript/3`, `get_session_transcript/3`, 2 private helpers, 2 aliases |
| `lib/alethea/clinical_record/audit.ex` | Modify | 1 action + 1 resource type |
| `lib/alethea/clinical_record/outbox.ex` | Modify | alias + spec + 1 `resource_type/1` clause |
| `lib/alethea/clinical_record/retention.ex` | Modify | alias + `@tables` entry + `identifiers_for/2` clause (F1) |
| `lib/alethea/clinical_record/tombstone.ex` | Modify | 1 resource type (F1) |
| `test/alethea/clinical_record/session_transcript_content_test.exs` | Create | Serializer/validation unit tests |
| `test/alethea/clinical_record/session_transcript_test.exs` | Create | Changeset + redaction unit tests |
| `test/alethea/clinical_record_test.exs` | Modify | Context authorization matrix + no-leak + outbox |
| `test/alethea/clinical_record/retention_test.exs` | Modify | Registration + crypto-erasure gating |
| `lib/alethea/clinical_record/rag/indexer.ex` | **Untouched (F2)** | #320 owns the eligibility clause |
| `lib/alethea_web/**` | **Untouched** | No UI in scope |

---

## Testing Strategy (Strict TDD — RED before GREEN)

| Layer | File | Coverage |
|---|---|---|
| Unit | `session_transcript_content_test.exs` | `new/1` accepts both speakers · rejects `"psychologist"`/`"Patient"`/`:patient` atom/`nil` with `:invalid_speaker` · rejects `[]` with `:empty_transcript` · rejects non-number `start`, `start > end`, non-binary `text`, missing key with `:invalid_span` · **one bad span in a 41-span list rejects the whole list** · `serialize/1` emits the sentinel and the exact `[format, version, [[s,e,spk,txt]]]` shape · `serialize |> parse` round-trips order, float timestamps, speakers, Unicode/emoji/newline text byte-for-byte · `parse/1` on missing sentinel, wrong format, wrong version, non-JSON, object-instead-of-array, 3-element span, bad speaker → `{:error, :malformed}` (never raises) · `speakers/0 == ~w(patient therapist)` |
| Unit | `session_transcript_test.exs` | `changeset/2` requires `encrypted_spans`/`recorded_at`/`patient_id`/`professional_id` · **`:spans` is not castable** (pass `spans:` ⇒ absent from changes) · `audio_duration_seconds` optional and castable · `encryption_version` defaults to 2 without being passed (AD3) · `inspect/1` on a struct with populated `:spans` does not contain the span text (`@derive` + `redact`) |
| Integration | `clinical_record_test.exs` | **Round-trip**: create with patient+therapist spans → `get_session_transcript/3` returns them with order, float timestamps, and speakers intact (AC1) · **No leak**: raw SQL `SELECT *` shows no span text/speaker in any column; `oban_jobs.args` has exactly the 5 identifier keys (AC2) · **Authorization**: professional B `create`/`get` on A's patient → `{:error, :unauthorized}` + exactly one `clinical_record_access_denied` audit row with `details == %{"outcome" => "denied"}` (AC3) · transcript id from another patient → `{:error, :not_found}` + denial row typed `session_transcript` · malformed UUID → `{:error, :not_found}` with `resource_id: nil` audited · **Write rejection**: a bad speaker → `{:error, :invalid_speaker}` **and** zero `session_transcripts`, zero success audit rows, zero `oban_jobs` (AC4) · **Outbox**: exactly one job, `event == "session_transcript_created"` (AC5) · `encryption_version == 2` on the persisted row · `audio_duration_seconds: nil` accepted, integer round-trips |
| Integration | `retention_test.exs` | `"session_transcript" in Retention.resource_types()` · `eligible_records(SessionTranscript, …)` returns identifiers only (no `encrypted_spans` key) · `legally_delete_record({"session_transcript", id})` inserts a tombstone, an audit row, and a `rag_purge` job (proves F1's `identifiers_for/2` + `Tombstone.@resource_types`) · **crypto-erasure gating**: with every other table at zero but one transcript remaining, `destroy_clinical_record_dek/1` does NOT fire; deleting the transcript then fires it |
| Regression | `composite_fk_test.exs`, `hypothesis_policy_test.exs` | **Unmodified, must stay green** — `composite_fk_test.exs:35-41` enumerates only target-behavior-bearing tables, so `session_transcripts` is correctly absent |

No E2E layer: #317 ships no UI and no producer, by design.

## Threat Matrix

N/A — no routing, shell, subprocess, VCS/PR automation, executable-file classification, or
process-integration boundary. The change is a DB table plus in-process serialization and AES-256-GCM
encryption through the existing `PatientVault`. The security-relevant surface is the
authorization/encryption/no-leak invariant set, which is covered as explicit integration tests above
(AC2, AC3, AC4) rather than as threat-matrix rows.

## Migration / Rollout

One additive migration, no backfill (the table is new and empty), no feature flag, no caller in any shipped
user path. Rollback: `mix ecto.rollback` one step drops `session_transcripts`; patient/professional rows are
untouched; the `Audit`/`Outbox`/`Retention`/`Tombstone` edits are additive list entries and vocabulary
clauses that cannot orphan rows because no transcript exists beforehand. Reverting Slice 2 alone leaves
Slice 1's table dormant and unreferenced — safe.

## Review Workload Forecast

**Decision needed before apply: Yes**
**Chained PRs recommended: Yes**
**400-line budget risk: High**

| Unit | Est. changed lines |
|---|---|
| `session_transcript.ex` (new) | ~60 |
| `session_transcript_content.ex` (new) | ~110 |
| migration (new) | ~40 |
| `session_transcript_content_test.exs` (new) | ~130 |
| `session_transcript_test.exs` (new) | ~65 |
| **Slice 1 subtotal** | **~405** |
| `clinical_record.ex` (2 public + 2 private fns, specs, docs) | ~120 |
| `audit.ex` / `outbox.ex` / `retention.ex` / `tombstone.ex` | ~15 |
| `clinical_record_test.exs` (authorization matrix, no-leak, outbox, rejection) | ~190 |
| `retention_test.exs` (registration + crypto-erasure gating) | ~70 |
| **Slice 2 subtotal** | **~395** |
| **Total** | **~800** |

As a single PR this is ~2× the budget. Recommended **Feature Branch Chain**:

- **PR 1 — storage primitives** (~405). Schema + content module + migration + both unit test files.
  Autonomous: the migration runs, the modules compile with no caller, and the serializer's validation
  contract (AC4's mechanism) is fully proven in isolation. Independently revertible; ships no behavior
  change to any live path.
- **PR 2 — context + registries** (~395), targeting PR 1's branch. `create`/`get`, the four registry edits,
  the authorization matrix, and the retention tests. This is where AC1/AC2/AC3/AC5 are proven.

Slice 1 sits ~1% over budget. Trim levers, in order: table-drive the speaker/span rejection cases via a
single module attribute plus a `for` comprehension (~−25), and drop the redundant "wrong version" +
"wrong format" parse cases into one table row (~−10). Both keep coverage identical.

## Open Questions

- [ ] **AD4 (`audio_duration_seconds` nullable)** refines D1, which locked only the column's *placement*.
      If the spec asserts a non-null duration, this design changes one line — but #317 then has no way to
      populate it, since audio capture is out of scope.
- [ ] **`new([])` rejects with `:empty_transcript`.** Neither the proposal nor the AC list mentions an
      empty transcript. Rejecting prevents meaningless encrypted rows that `Retention` must then track;
      accepting defers the policy to #320. Flagged for spec reconciliation — allowing `[]` is a one-clause
      deletion.
- [ ] **AD7 (single composite index)** deviates from the sibling tables' `[:patient_id]` habit for a
      provable-redundancy reason. Reviewer-vetoable; restoring it is one line.
