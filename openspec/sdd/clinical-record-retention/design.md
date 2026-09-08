# Design — clinical-record-retention

**Source issue:** alethea-org/Alethea#197
**Builds on:** `openspec/sdd/clinical-record-retention/proposal.md` (BR1–BR12, D1–D5 are fixed inputs, not re-derived here) and `openspec/adr/003-rag-historia-clinica-navegable.md`.
**Artifact store:** hybrid — mirrored to Engram `sdd/clinical-record-retention/design`.

> **Size note.** The `sdd-design` 800-word budget is deliberately exceeded: the launch contract required concrete migrations, function signatures and module boundaries for seven items. Prose is kept minimal; the weight is in tables and code blocks.

## Technical Approach

Four new modules plus surgical edits at existing seams. Nothing in `Alethea.Clinical` is touched.

| Module | Kind | Responsibility |
|---|---|---|
| `Alethea.ClinicalRecord.Lifecycle` | new | Patient-scoped hold + stricter-minimum state (D3) |
| `Alethea.ClinicalRecord.Tombstone` | new | Per-record content-free tombstone (D5) |
| `Alethea.ClinicalRecord.Retention` | new | Eligibility query + `legally_delete_record/2` primitive + BR11 iteration |
| `AletheaJobs.RetentionSweepWorker` | new | Oban cron trigger (BR4-A), calls the same primitive |
| `Alethea.ClinicalRecord` | modify | D4 read/write gate; dual-key read seam |
| `Alethea.Accounts` / `Accounts.EncryptionKey` | modify | CR-scoped key type: lazy create, scoped destroy (D1) |
| `Alethea.ClinicalRecord.Outbox` | modify | `tombstone_event/4` |
| `Alethea.ClinicalRecord.Rag.Indexer` | modify | `{:tombstone, _}` clause + purge branch |

## Architecture Decisions

### AD1 — D1 backfill: **no ciphertext backfill at all; dual-read by `encryption_version`**

**Choice.** Existing rows stay exactly as they are — `encryption_version = 1`, encrypted under the shared patient DEK. Rows written *after* this ships are `encryption_version = 2`, encrypted under the new `"patient_clinical_record"` key. Reads select the key per row. No migration, worker or request path ever re-encrypts anything.

**State of pre-change rows the instant this ships:** fully readable, byte-identical, zero risk of unreadability. There is no window in which existing data depends on a key that does not yet exist.

**Two code facts forced this.**

1. **The KEK is *not* session-bound.** `Alethea.Encryption.ProfessionalKek.load_kek/1` (`lib/alethea/encryption/professional_kek.ex:38`) decrypts the KEK under the global Cloak `Vault` (app secret), so *any* Mix task or Oban worker can recover it — `Rag.Indexer`'s moduledoc already states this ("the KEK is server-recoverable in a worker, no session needed for ingest"). Only a bare `Ecto.Migrator` process cannot, because it must not reference app schemas. **The proposal's High-risk framing ("needs a professional KEK the migration process does not have") is therefore over-stated: a Mix task or worker was always viable.** Risk downgrades to Low.
2. **Two of the six tables are physically un-updatable.** `clinical_notes` and `consultation_evidences` carry DB-level `BEFORE UPDATE` triggers (proven by `test/alethea/clinical_record_test.exs:288-298`, which asserts a raw `UPDATE` raises `Postgrex.Error`). A rekey backfill would have to `DROP` those triggers — trading a hard immutability guarantee for a bounded backup-window guarantee. Wrong trade.

**Alternatives rejected.**

| Option | Why rejected |
|---|---|
| Lazy on-next-access re-wrap (decrypt v1 → re-encrypt v2 on read) | Turns every read into a write; impossible on the two immutable tables; and on `clinician_observations`/`ai_proposals`/`functional_analysis_drafts` an `updated_at` bump would **restart that record's own retention clock (BR5)** — a retention bug caused by an encryption concern |
| Operator Mix task that rekeys everything | Same trigger blocker; also needs `DROP TRIGGER` privileges |
| Derive the CR key deterministically from the patient DEK | Undestroyable — regenerating it is trivial, so crypto-erasure becomes meaningless |
| Plain Ecto migration | Cannot start Cloak/app schemas; schema drift |

**Accepted residual (needs product-owner acknowledgement — see Open Questions).** Legacy `v1` rows are **hard-delete-only forever**; their backup ciphertext stays decryptable under the shared patient DEK, which BR3 forbids destroying. This is BR12's accepted window, but *permanent* rather than bounded-until-zero, and scoped only to rows predating this change.

**Optional mitigation — declined.** A `mix alethea.clinical_record.rekey` task was considered (modelled on `lib/mix/tasks/alethea.rag.reindex.ex`) but the product owner accepted the AD1 residual as-is; this task is dropped from scope entirely, not just deferred.

### AD2 — Retention timestamp is the row's own **write** time, never `occurred_at`

| Table | `retention_at` | Rationale |
|---|---|---|
| `target_behaviors` | `inserted_at` | immutable-by-use |
| `clinical_notes` | `inserted_at` | immutable (trigger) |
| `consultation_evidences` | `inserted_at` | immutable (trigger) — see below |
| `clinician_observations` | `updated_at` | mutable in place |
| `ai_proposals` | `updated_at` | mutable in place |
| `functional_analysis_drafts` | `updated_at` | mutable in place |

**Choice:** two shapes, not three. **Alternative rejected:** the proposal's "occurred-at-bearing → `occurred_at`". `occurred_at` is a *historical* facet (a citation copies its source's original date, potentially years old) and three tables carry both `occurred_at` and `updated_at`, so the proposal's mapping overlaps. **Rationale:** using `occurred_at` would delete a record *earlier* than the clinical action that created it. Retention may over-retain; it must never under-retain. This is consistent with BR5 ("its **own** last-clinical-action timestamp") — a copied historical date is not an action on the row.

### AD3 — Effective retention is `GREATEST(baseline, override)`

A stricter *minimum* retention keeps content **longer**, so "stricter wins" is `max`, computed in SQL per row against the left-joined lifecycle row. `NULL` override ⇒ baseline.

### AD4 — Deletion is one transaction **per record**, never one per patient

BR6 makes mixed state legal, so a whole-patient manual deletion (BR11) is a bounded `Enum.reduce_while` over the per-record primitive, **not** a single transaction. A partial result is a valid reportable outcome, not a rollback. Sequential, never `Task.async_stream/3`: the terminal zero-remaining crypto-erasure check (D1/D2) is a read-then-act on a shared counter and concurrency would race it into a premature key destruction. The retention queue is registered with concurrency `1` for the same reason.

### AD5 — Audit attribution without an Audit schema change

`Audit.changeset/1` requires `professional_id`, and the sweep has no acting professional. Every one of the six tables already carries `professional_id` (the author). **Choice:** sweep deletions attribute the audit row to the record's *author*; manual deletions attribute it to the *acting* professional. The `trigger` column on the tombstone (`"sweep" | "manual"`) carries the distinction. Confirms the proposal's "no `@resource_types` or schema change is needed".

## Data Flow

```
RetentionSweepWorker (cron, gated off)          Manual (LiveView / context call)
        │ per table: indexed range scan                    │ authorize once
        │ LEFT JOIN lifecycle, hold IS NULL                │ hold check once
        └──────────────┬───────────────────────────────────┘
                       ▼
      Retention.legally_delete_record({type, id}, opts)     ── ONE record, ONE Ecto.Multi
          :record        Repo.delete_all(where id)          (identifiers selected only —
          :tombstone     insert content-free row             the sweep never loads ciphertext
          :audit         Audit "clinical_record_legally_deleted"   and never loads a DEK)
          :rag_purge     Oban.insert(Outbox.tombstone_event/4)
          :crypto_erase  Multi.run → if remaining_rows(patient) == 0
                                     destroy type="patient_clinical_record" row ONLY
                       │
                       ▼ (after commit)
      ClinicalRecordOutboxWorker → Indexer.index_event/1
          eligibility("clinical_record_legally_deleted") → {:tombstone, :legal_deletion}
          └─ replace_chunks({type, id}, [])   ← short-circuits BEFORE Professional/Patient
                                                lookup, load_*_kek, load_*_dek,
                                                fetch_and_decrypt/3. Structurally
                                                incapable of decrypting, so it still
                                                works after the CR key is destroyed.

Read  a deleted record ──► Tombstone row → content-free "legally deleted on {date}"  (BR10)
Write a deleted record ──► Audit.log_denied + {:error, :legally_deleted}             (D4)
Siblings                ──► untouched, fully readable                                (BR6)
```

## Migrations

All generated with `mix ecto.gen.migration` (never hand-written).

**(a) `create_clinical_record_lifecycles`** — patient-scoped, deliberately *not* `patients.status`:

```elixir
create table(:clinical_record_lifecycles, primary_key: false) do
  add :id, :binary_id, primary_key: true
  add :patient_id, references(:patients, type: :binary_id, on_delete: :delete_all), null: false
  add :legal_hold_at, :utc_datetime                # NULL = no active hold
  add :legal_hold_by_id, references(:professionals, type: :binary_id, on_delete: :restrict)
  add :legal_hold_released_at, :utc_datetime
  add :retention_minimum_days, :integer            # NULL = global baseline (BR7)
  timestamps(type: :utc_datetime)
end

create unique_index(:clinical_record_lifecycles, [:patient_id])
create index(:clinical_record_lifecycles, [:legal_hold_at])
```

Row is created lazily on first hold/override; its absence means "no hold, global baseline" — hence `left_join` + `coalesce` everywhere.

**(b) `create_clinical_record_tombstones`** (D5) — content-free by construction: no free-text column exists, and both string columns are closed vocabularies validated by `validate_inclusion/3`.

```elixir
create table(:clinical_record_tombstones, primary_key: false) do
  add :id, :binary_id, primary_key: true
  add :resource_type, :string, null: false          # the 6 existing @resource_types
  add :resource_id, :binary_id, null: false
  add :patient_id, references(:patients, type: :binary_id, on_delete: :delete_all), null: false
  add :target_behavior_id, :binary_id               # nullable, NO FK — see below
  add :deleted_at, :utc_datetime, null: false
  add :deleted_by_id, references(:professionals, type: :binary_id, on_delete: :restrict)
  add :trigger, :string, null: false                # "sweep" | "manual"
  timestamps(type: :utc_datetime, updated_at: false)
end

create unique_index(:clinical_record_tombstones, [:resource_type, :resource_id])
create index(:clinical_record_tombstones, [:patient_id, :deleted_at])
create index(:clinical_record_tombstones, [:target_behavior_id])
```

`target_behavior_id` is required by the **read** path: once the content row is hard-deleted, `review_timeline/3` has no other way to know which tombstones belong to the timeline it is rendering. It carries **no FK** — under BR5's independent clocks the parent `target_behavior` can itself be deleted while a child survives, exactly the `ConsultationEvidence.source_id` no-FK precedent.

**(c) CR-scoped key type (D1).** `encryption_keys.type` is a plain `:string` with **no** check constraint and **no** unique index on `patient_id` (verified: `priv/repo/migrations/20260512151206_update_accounts_and_keys.exs:11-22`), so a second row per patient needs **no DDL for the type itself** — only the allowlist widening in `Accounts.EncryptionKey.changeset/2`:

```elixir
|> validate_inclusion(:type, ["patient", "professional", "patient_clinical_record"])
```

One migration is still required, to make lazy creation race-safe:

```elixir
create unique_index(:encryption_keys, [:patient_id, :type], where: "patient_id IS NOT NULL")
```

Without it, two concurrent first-writes create two CR key rows and one row's ciphertext becomes permanently undecryptable. Lazy creation therefore uses `on_conflict: :nothing` + re-read.

**(d) `add_encryption_version_to_clinical_record_tables`** — `clinician_observations`, `ai_proposals` and `functional_analysis_drafts` are the three of six that lack the column (the other three and `clinical_record_rag_chunks` already have it). `add :encryption_version, :integer, null: false, default: 1` — required for AD1's dual-read to be uniform.

**(e) `add_retention_indexes`** — no index on any retention timestamp exists today:

```elixir
create index(:target_behaviors, [:inserted_at])
create index(:clinical_notes, [:inserted_at])
create index(:consultation_evidences, [:inserted_at])
create index(:clinician_observations, [:updated_at])
create index(:ai_proposals, [:updated_at])
create index(:functional_analysis_drafts, [:updated_at])
```

## Interfaces / Contracts

### Eligibility query (one per table, same shape)

```elixir
# Alethea.ClinicalRecord.Retention
@spec eligible_records(module(), keyword()) :: [%{resource_type: String.t(),
                                                  resource_id: Ecto.UUID.t(),
                                                  patient_id: Ecto.UUID.t(),
                                                  professional_id: Ecto.UUID.t(),
                                                  retention_at: DateTime.t()}]
```

```elixir
from(r in ClinicianObservation,
  left_join: l in Lifecycle, on: l.patient_id == r.patient_id,
  where: is_nil(l.legal_hold_at),                                       # BR2, once per patient
  where:
    fragment(
      "? <= ? - make_interval(days => ?)",
      r.updated_at,                                                     # AD2 retention_at
      ^now,
      fragment("GREATEST(?, COALESCE(?, ?))",                           # AD3 stricter wins
        ^baseline_days, l.retention_minimum_days, ^baseline_days)
    ),
  order_by: [asc: r.updated_at, asc: r.id],                             # keyset-stable
  limit: ^batch_size,
  select: %{resource_type: "clinician_observation", resource_id: r.id,
            patient_id: r.patient_id, professional_id: r.professional_id,
            retention_at: r.updated_at}
)
```

- **`left_join`, not `join`** — the lifecycle row is lazily created; a patient without one must still be eligible.
- **`is_nil(l.legal_hold_at)`** — a `LEFT JOIN` miss yields `NULL`, which passes, correctly meaning "no hold".
- **`select:` identifiers only** — no `encrypted_*` column is ever loaded by the sweep. That is the mechanical proof of the proposal's "the sweep can never decrypt anything".
- **No tombstone exclusion needed** — deletion is a hard delete, so an already-swept row cannot reappear. The sweep is naturally idempotent.
- **Index used:** the new single-column index on `retention_at` drives the range scan; the lifecycle join hits `unique_index([:patient_id])`.

### Deletion primitive

```elixir
# Alethea.ClinicalRecord.Retention
@type resource_ref :: {resource_type :: String.t(), resource_id :: Ecto.UUID.t()}

@spec legally_delete_record(resource_ref(), keyword()) ::
        {:ok, Tombstone.t()}
        | {:error, :not_found | :legal_hold_active | :already_deleted | term()}
# opts: [actor: %Professional{} | :system, trigger: "sweep" | "manual"]
```

Loads the row selecting identifiers only, re-checks the hold (the sweep's batch may be stale), then one `Ecto.Multi`: `:record` (`delete_all` by id) → `:tombstone` → `:audit` → `:rag_purge` (`Oban.insert`) → `:crypto_erasure` (`Multi.run`, fires only at zero remaining rows across all six tables, per D1 verbatim).

```elixir
# BR11 — whole-patient, bounded iteration over the SAME primitive
@spec legally_delete_patient_record(Professional.t(), Ecto.UUID.t(), keyword()) ::
        {:ok, %{deleted: non_neg_integer(), tombstones: [Tombstone.t()]}}
        | {:error, :unauthorized | :legal_hold_active | {:partial, non_neg_integer(), term()}}
```

Authorizes once via `Accounts.get_patient_for_professional/2`, checks the hold once, then `Enum.reduce_while` over every ref. **Not** one transaction (AD4).

### Hold API

```elixir
# Alethea.ClinicalRecord.Lifecycle
@spec apply_hold(Professional.t(), Ecto.UUID.t()) :: {:ok, t()} | {:error, :unauthorized | term()}
@spec release_hold(Professional.t(), Ecto.UUID.t()) :: {:ok, t()} | {:error, :unauthorized | term()}
@spec held?(Ecto.UUID.t()) :: boolean()
@spec set_retention_minimum(Professional.t(), Ecto.UUID.t(), pos_integer() | nil) :: {:ok, t()} | {:error, term()}
@spec effective_retention_days(t() | nil) :: pos_integer()   # max(baseline, override)
```

New `Audit` `@actions` entries only: `legal_hold_applied`, `legal_hold_released`, `clinical_record_legally_deleted`, `clinical_record_key_destroyed`. `@resource_types` unchanged.

### Key model (D1) — new functions, existing ones untouched

```elixir
# Alethea.Accounts
@spec load_clinical_record_dek(Patient.t(), binary()) :: {:ok, binary()} | {:error, :not_found | term()}
@spec ensure_clinical_record_dek(Patient.t(), binary()) :: {:ok, binary()} | {:error, term()}  # lazy, on_conflict: :nothing
@spec destroy_clinical_record_dek(Ecto.UUID.t()) :: {:ok, :destroyed} | {:ok, :absent}
```

```elixir
def destroy_clinical_record_dek(patient_id) do
  EncryptionKey
  |> where([k], k.patient_id == ^patient_id and k.type == "patient_clinical_record")
  |> Repo.delete_all()                       # type literal is the whole safety property
  |> case do
    {0, _} -> {:ok, :absent}
    {_n, _} -> {:ok, :destroyed}
  end
end
```

### Dual-read seam (AD1) in `lib/alethea/clinical_record.ex`

```elixir
@type keyring :: %{patient_dek: binary(), clinical_record_dek: binary()}

defp with_patient(professional, patient_id, fun)   # fun.(patient, keyring) — was fun.(patient, dek)

defp dek_for(%{encryption_version: 1}, keyring), do: keyring.patient_dek
defp dek_for(%{encryption_version: 2}, keyring), do: keyring.clinical_record_dek
```

Writes stamp `encryption_version: 2` and encrypt under `keyring.clinical_record_dek`. `review_timeline/3` mixes v1 and v2 rows, so the keyring (not a single DEK) is what must flow. `Rag.Indexer.index_resource/5` and `Rag.Retrieval` take the same treatment — `Chunk` already has `encryption_version`.

### D4 gate — exact edit sites

Every mutable write already ends in `Repo.get_by(Schema, id: ..., patient_id: ...) → nil → {:error, :not_found}`
(`clinical_record.ex:247`, `:358`, `:579`). That `nil` branch becomes the gate:

```elixir
nil ->
  case Tombstone.for_resource(resource_type, resource_id) do
    %Tombstone{} -> deny_access(professional.id, resource_id, resource_type)  # {:error, :legally_deleted}
    nil -> {:error, :not_found}
  end
```

`deny_access/2` widens to `deny_access/3` (it already passes `"patient"` positionally into `Audit.log_denied/3`) and returns `{:error, :legally_deleted}` on this path — an explicit policy answer, never an indistinguishable `:not_found` (D4's stated rationale).

Reads: `review_timeline/3` additionally queries `Tombstone` by `target_behavior_id` and merges `%{kind: :legally_deleted, occurred_at: deleted_at, resource_type: ...}` into the existing `Enum.sort_by(&{&1.occurred_at, kind_rank(&1.kind), &1.id})` — one new `kind_rank/1` clause. `get_functional_analysis_draft/3` returns `{:ok, {:legally_deleted, deleted_at}}` instead of `{:ok, nil}` when a tombstone exists.

### RAG indexer

```elixir
# eligibility/1 — one clause ABOVE the existing catch-all, zero restructuring
def eligibility("clinical_record_legally_deleted"), do: {:tombstone, :legal_deletion}

@type eligibility_result ::
        {:index, atom()} | {:tombstone, atom()} | {:ignore, atom()} | {:unknown, String.t()}

# index_event/1 — purge branch, placed BEFORE the {:index, _} clause
{:tombstone, _reason} ->
  case replace_chunks({resource_type, resource_id}, []) do
    {:ok, _rows} -> :ok
    {:error, reason} -> {:error, reason}
  end
```

It never reaches `Repo.get(Professional, …)`, `load_professional_kek/1`, `load_patient_dek/2` or `fetch_and_decrypt/3`. `replace_chunks/2`'s existing delete-then-`insert_all` degenerates to delete-only with `[]`, exactly ADR-003's immediate-delete mechanism, and is idempotent on Oban retry.

```elixir
# Alethea.ClinicalRecord.Outbox — Outbox.event/2 needs a persisted struct; the row is being deleted
@spec tombstone_event(String.t(), Ecto.UUID.t(), Ecto.UUID.t(), Ecto.UUID.t()) :: Ecto.Changeset.t()
```

Same `@allowed_args` `Map.take/2` allowlist, same `ClinicalRecordOutboxWorker`, same queue.

### Sweep worker

```elixir
defmodule AletheaJobs.RetentionSweepWorker do
  use Oban.Worker, queue: :clinical_record_retention, max_attempts: 1
```

New queue `clinical_record_retention: 1` in `config/config.exs` — concurrency **1** serializes destructive work and prevents racing the terminal zero-remaining check (AD4). Crontab gains `{"30 3 * * *", AletheaJobs.RetentionSweepWorker}`.

Ships inert by two independent guards, per the proposal's rollback plan:

```elixir
def perform(%Oban.Job{args: args}) do
  cond do
    not Application.get_env(:alethea, :retention_sweep_enabled, false) -> log_and_ok(:disabled)
    Map.get(args, "dry_run", true) -> report_eligible_counts()   # dry-run is the DEFAULT
    true -> sweep()
  end
end
```

`max_attempts: 1` — a retry of a partially-completed destructive sweep has no value; the next nightly run picks up whatever remains.

## D1 / BR3 boundary — functions this change MUST NOT touch

| File:line | Function | Why it must stay unchanged |
|---|---|---|
| `lib/alethea/clinical.ex:348` | `patient_dek/1` | Decrypts journaling under the shared `"patient"` DEK — the exact key BR3 forbids destroying |
| `lib/alethea/clinical.ex:344` | `get_dek/2` | Same key path |
| `lib/alethea/clinical.ex:340` | `decrypt_message_content/2` | Same key path |
| `lib/alethea/accounts.ex:121` | `load_patient_dek/2` | Its `type: "patient"` literal must **not** be widened; the CR key gets a new function |
| `lib/alethea/accounts.ex:209` | `get_encryption_key_for_patient/1` | `type == "patient"` literal must stay |
| `lib/alethea/accounts.ex:221` | `create_patient/2` | Still creates exactly **one** `"patient"` DEK; the CR key is lazy, never created here |
| `lib/alethea/encryption/patient_vault.ex` | all | AES-256-GCM primitive, key-agnostic — no signature change |
| `lib/alethea/encryption/vault.ex`, `professional_kek.ex` | all | KEK wrapping unchanged |
| `lib/alethea/clinical/{message,summary,trend}.ex` | schemas | Out of blast radius entirely |
| `patients.status`, `Accounts.archive_patient/1` | — | D3: `"deleted"` stays unused |

The single enforcement point is the `type == "patient_clinical_record"` literal in `destroy_clinical_record_dek/1`. It gets a mandatory RED test asserting the `"patient"` row survives a terminal erasure and that journaling still decrypts afterwards.

## File Changes

| File | Action |
|---|---|
| `lib/alethea/clinical_record/lifecycle.ex` | Create |
| `lib/alethea/clinical_record/tombstone.ex` | Create |
| `lib/alethea/clinical_record/retention.ex` | Create |
| `lib/alethea_jobs/retention_sweep_worker.ex` | Create |
| `priv/repo/migrations/*` | Create ×5 (a–e above) |
| `lib/alethea/clinical_record.ex` | Modify — keyring dual-read, D4 gate, `deny_access/3` |
| `lib/alethea/clinical_record/audit.ex` | Modify — 4 new `@actions` |
| `lib/alethea/clinical_record/outbox.ex` | Modify — `tombstone_event/4` |
| `lib/alethea/clinical_record/rag/indexer.ex` | Modify — tombstone clause + purge branch + v2 key selection |
| `lib/alethea/clinical_record/rag/retrieval.ex` | Modify — dual-read by chunk `encryption_version` |
| `lib/alethea/accounts.ex`, `accounts/encryption_key.ex` | Modify — CR key type, lazy create, scoped destroy |
| `config/config.exs` | Modify — queue + crontab + `:retention_sweep_enabled` (false) + `:retention_baseline_days` (3650) |
| `lib/alethea/clinical_record/source_ref.ex` | Verify only — `:unavailable` path already covers erased sources |
| `lib/alethea/clinical.ex` | Verify only — must not change |

## Testing Strategy

| Layer | What | Approach |
|---|---|---|
| Unit | AD2 timestamp mapping; `effective_retention_days/1` = `max`; exact-threshold boundary in UTC | Pure function tests, no DB |
| Unit | `eligibility("clinical_record_legally_deleted") == {:tombstone, :legal_deletion}`; `replace_chunks(ref, [])` deletes all | Existing indexer test file |
| Integration | Mixed state: patient with 1 tombstoned + 2 active records; siblings still decrypt | `Repo` sandbox |
| Integration | Hold pauses **every** record regardless of clock; lift re-exposes each own clock | `Repo` sandbox |
| Integration | Dual-read: a v1 row and a v2 row on the same patient both decrypt in one `review_timeline/3` | Insert a v1 fixture directly |
| Integration | **Key-boundary RED test** — terminal erasure destroys `"patient_clinical_record"` only; `Clinical.patient_dek/1` still works | Assert both `encryption_keys` rows before, one after |
| Integration | Zero-remaining fires exactly once, never while a sibling lives | Count `encryption_keys` after each deletion |
| Integration | Write to a tombstoned record → `{:error, :legally_deleted}` + one `clinical_record_access_denied` audit row, content-free | Reuse `clinical_record_test.exs:300` content-free assertions |
| Integration | Orphaned parent: `target_behavior` deleted, child observation survives and renders the parent's tombstone without raising | Timeline render |
| Integration | `SourceRef.resolve/2` → `:unavailable` for a legally deleted `clinical_note`; the citing evidence still renders its own excerpt | Existing degradation path |
| Worker | Sweep is inert when `:retention_sweep_enabled` is false; dry-run default reports counts and writes nothing | Oban testing mode |
| Query | Patient with **no** lifecycle row is still eligible (`left_join` correctness) | `Repo` sandbox |

## Threat Matrix

**N/A** — no routing, shell command, subprocess, VCS/PR automation, executable-file classification, or process-integration boundary. The optional Mix task is a local operator CLI matching `alethea.rag.reindex` exactly: two `OptionParser` switches, `Ecto.UUID.cast/1` validation, no `String.to_atom/1` on input, no shell invocation, no HTTP.

**Destructive-surface safeguards** (not a threat-matrix row, but required by the proposal's rollback plan): cron ships behind `:retention_sweep_enabled = false`; the worker's dry-run default is `true`; queue concurrency is `1`; `max_attempts: 1`; the manual path requires explicit confirmation (BR9); and the sweep's `select:` clause makes it structurally unable to load ciphertext.

## Migration / Rollout

No data migration. Schema-only (five migrations), all reversible. Pre-change rows are untouched and stay readable (AD1). Rollout order: migrations → dual-read + key model → gate + tombstones → sweep (inert) → verify in production with dry-run output → flip `:retention_sweep_enabled`. Rollback before the flag is flipped is an ordinary PR revert plus `mix ecto.rollback`; after it, erasure is irreversible by design.

## Delivery size (input to `sdd-tasks`, not a forecast)

`sdd-tasks` owns the guard lines. Design's honest estimate of authored lines including strict-TDD tests:

| Slice | Content | Est. lines |
|---|---|---|
| A | Migrations (a)(b)(e) + `Lifecycle` + `Tombstone` + hold API + audit vocabulary + D4 gate | 350–450 |
| B | Migrations (c)(d) + CR key type + lazy create + `destroy_*` + keyring dual-read across `clinical_record.ex`, `indexer.ex`, `retrieval.ex` | 450–600 |
| C | `Retention` (eligibility + primitive + BR11) + `RetentionSweepWorker` + config + `Outbox.tombstone_event/4` + indexer tombstone clause | 400–500 |
| D | LiveView tombstone affordance | 150–250 |

**Total ≈ 1350–1800 authored lines.** This session's cached review budget is 800 lines (not `openspec/config.yaml`'s repo-wide default of 400) — roughly 1.7–2.25× that budget. The cached `delivery_strategy` is `single-pr`, which this still does not fit. Slices A→B→C→D are each independently deliverable, verifiable and revertible (C is inert until the flag flips). `sdd-tasks` must forecast against the 800-line session budget and the orchestrator must resolve the conflict before apply; this design does not silently assume chaining.

## Open Questions — CLOSED

- [x] **AD1 residual.** Product owner accepted as-is: legacy (pre-change) rows are permanently hard-delete-only, no rekey task funded. Slice D's optional `mix alethea.clinical_record.rekey` is dropped from scope.
- [x] **AD2 timestamp mapping for `consultation_evidences`.** Confirmed: `inserted_at`, not `occurred_at`, per the design's under-retention rationale.
- [x] `retention_minimum_days` as integer days (not years) — accepted per design's rationale (generalizes, keeps `make_interval` trivial), no separate confirmation needed.
