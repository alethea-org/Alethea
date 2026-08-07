# Design — retire-whatsapp-patient-identity (#107)

## Technical approach

Clean mechanical removal of the WhatsApp identity surface. Delete only phone-specific lines; the DEK/KEK envelope and `EncryptionKey` linkage stay untouched (they encrypt MESSAGE content, not the phone). Single PR, single migration, no production data.

## Two findings beyond the exploration checklist

**A. Hidden runtime break — `send_consent_terms/1` (accounts.ex:399-413).** It reads `patient.encrypted_whatsapp_number` (:401); once that field drops, struct dot-access raises `KeyError` at runtime. Its body is a dead TODO no-op. **Delete `send_consent_terms/1` and its only call site (accounts.ex:305).** Its internal `get_patient_with_professional/1` stays (used by telegram workers).

**B. `save_message` slot-6 `nil` has TWO callers**, both fixed in the same commit as the signature change:
1. `clinical.ex:144` — `save_message(legacy, text, nil, dir, bt, nil, session_id, tg_id)`
2. `test/alethea_jobs/session_timeout_worker_test.exs:43`

## Architecture decisions

**ADR-1 — Migration reversibility: explicit `up`/`down`.** A `change` using `remove/1` is irreversible, and `drop table` in `change` is non-invertible — both raise on `ecto.rollback`. Chosen: explicit `up`/`down`; `down` recreates columns (nullable) + indexes + the consent_logs table.

**ADR-2 — Index drops rely on Postgres column-cascade.** Postgres auto-drops an index when its column drops, so an explicit `drop unique_index(...)` after `remove :col` ERRORS ("index does not exist"). In `up`, only `remove` the columns. In `down`, recreate columns first, then `create unique_index`.

**ADR-3 — Compile-break ordering (HARD CONSTRAINT).** Two atomic same-commit pairings:
- `patient.ex` field removal ⟺ `daily_scheduler_worker_test.exs` struct-literal fix (:34-42, 45-53, 81-89).
- `save_message` signature change ⟺ both call sites (clinical.ex:144, session_timeout_worker_test.exs:43).

## create_patient/2 — resulting shape

Remove: whatsapp extraction (:242), the blank-check `cond` (:244-252, whole cond — no branching left), `normalize_phone` call (:256), phone encrypt (:265), phone-hash block (:268-275), the two `Map.put` (:292-293), and the `send_consent_terms(patient)` call (:305). Keep: attrs normalization, DEK gen (:259), KEK wrap (:262), the full `Ecto.Multi` (encryption_key insert / patient insert / finalize_key), PubSub + audit side-effects. Blank input now errors via `validate_required([:alias, :professional_id])` → `{:error, %Ecto.Changeset{}}` (same shape callers handle). Verified: `PatientVault`/DEK never derive from the phone.

## save_message new signature (clinical.ex)

```elixir
def save_message(patient, text, dek, direction, behavior_type, session_id \\ nil, telegram_message_id \\ nil)
```
Remove the `whatsapp_message_id \\ nil` param, the `if whatsapp_message_id` attrs block (:49-52), and the whatsapp dedup `cond` branch (:68-72). Drop `{:error, :duplicate, Message.t()}` from the `@spec` (WhatsApp was its only producer). Fix the two callers.

## Migration (exact)

```elixir
defmodule Alethea.Repo.Migrations.RetireWhatsappPatientIdentity do
  use Ecto.Migration

  def up do
    alter table(:patients) do
      remove :whatsapp_number_hash       # cascades patients_whatsapp_number_hash_index
      remove :encrypted_whatsapp_number
    end
    alter table(:messages) do
      remove :whatsapp_message_id        # cascades the partial unique index
    end
    drop table(:whatsapp_consent_logs)
  end

  def down do
    create table(:whatsapp_consent_logs, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :whatsapp_number, :string, null: false
      add :status, :string, null: false
      add :phone_hash, :string
      add :event_type, :string
      add :inserted_at, :utc_datetime, null: false, default: fragment("now()")
      add :updated_at, :utc_datetime, null: false, default: fragment("now()")
    end
    create index(:whatsapp_consent_logs, [:whatsapp_number])
    create index(:whatsapp_consent_logs, [:phone_hash])
    create index(:whatsapp_consent_logs, [:status])

    alter table(:messages) do
      add :whatsapp_message_id, :string
    end
    create unique_index(:messages, [:whatsapp_message_id], where: "whatsapp_message_id IS NOT NULL")

    alter table(:patients) do
      add :whatsapp_number_hash, :string      # nullable in down (safe rollback)
      add :encrypted_whatsapp_number, :binary
    end
    create unique_index(:patients, [:whatsapp_number_hash])
  end
end
```
Note: the `down` consent_logs DDL is a best-effort reconstruction; git-revert is the real rollback path (no data). Verify the original consent_logs column set against `20250601160000` at apply time.

## File changes

| File | Action | Description |
|------|--------|-------------|
| `lib/alethea/accounts.ex` | Modify | strip phone lines in create_patient/2; delete lookup_patient_by_phone/1, normalize_phone/1, send_consent_terms/1 + its call |
| `lib/alethea/accounts/patient.ex` | Modify | drop fields :8-9 + virtual :19, cast :35-37, unique_constraint :53-55 |
| `lib/alethea/clinical.ex` | Modify | drop whatsapp param/attrs/dedup; fix :144 call; trim @spec |
| `lib/alethea/clinical/message.ex` | Modify | drop field :10, cast :39, unique_constraint :62 |
| `lib/alethea_web/live/patient_live/index.ex` | Modify | remove input block :291-308 + privacy-copy line :270 |
| `priv/repo/migrations/<ts>_retire_whatsapp_patient_identity.exs` | Create | up/down: 3 cols + 2 indexes + consent_logs table |
| `test/alethea_jobs/daily_scheduler_worker_test.exs` | Modify | remove struct keys (SAME COMMIT as schema) |
| `test/alethea_jobs/session_timeout_worker_test.exs` | Modify | drop positional nil slot 6 (SAME COMMIT as save_message) |
| `test/alethea/accounts_test.exs` | Modify | rewrite create_patient block, delete lookup_patient_by_phone block |
| ~7 stale-param test files | Modify | drop ignored `"whatsapp_number"` keys (non-breaking) |

## accounts_test.exs rewrite

Delete `describe "lookup_patient_by_phone/1"` (:191-220). In the create_patient describe (:22-189) delete all whatsapp assertions. Keep/add: (a) alias-only create → `{:ok, patient}`; (b) an `EncryptionKey` type "patient" provisioned + `patient.encryption_key_id` set; (c) missing alias → `{:error, %Ecto.Changeset{}}`; (d) message encrypt/decrypt round-trip via the provisioned DEK (encryption regression per project rule).

## Form edit

Remove the WhatsApp `<div>` input block (:291-308) and the privacy-copy `<p>` (:270); trim the privacy badge to channel-neutral copy. `@form[:whatsapp_number]` appears only inside the removed block; the form derives from `Patient.changeset(%Patient{}, %{})` → `to_form` still renders once the virtual field drops.

## Review workload forecast

Single PR, ~250-350 changed lines (accounts_test rewrite dominates). **400-line budget risk: Low.** No chaining.

## Judgment-day outcome (2 judges; risk lens declined — native-binding contract)

0 blockers. Both judges verified the KEK/DEK envelope is intact. Fixes applied in-PR: stale WhatsApp `{:error, :duplicate}` docstring in `clinical.ex` cleaned; orphaned `phone_hash_secret` config removed (runtime/dev/test — no lib consumer after `normalize_phone`/`lookup_patient_by_phone` removal). **Accepted (intentional, ADR-1):** the migration `down` recreates the patients whatsapp columns as **nullable** (original was `null: false`) — deliberate so `ecto.rollback` never fails; git-revert is the real rollback path (no data).
