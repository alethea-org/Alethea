defmodule Alethea.Repo.Migrations.AddBurstCoverageToMessages do
  @moduledoc """
  Adds burst-reply coverage to inbound Telegram messages (issue #391).

  `replied_by_message_id` is set on an INBOUND row, pointing at the
  OUTBOUND reply that covered it — the opposite direction from
  `reply_to_message_id` (#390), which records provenance on the reply
  itself. Coverage is many-to-one (every member of a burst points at
  the single reply that answered the burst), so no uniqueness
  constraint applies here, unlike `reply_to_message_id`'s partial
  unique index.

  `IS NULL` is the single source of truth for "needs a reply": the
  partial index `messages_uncovered_inbound_index` on `(patient_id)
  WHERE direction = 'inbound' AND replied_by_message_id IS NULL` is
  what the burst worker (#391, S2) scans. The second partial index,
  `messages_replied_by_message_id_index` on `(replied_by_message_id)
  WHERE NOT NULL`, serves the release/absorb lookups added in S2/S3.

  `delivery_state` gains `"superseded"` — a reply whose coverage was
  reclaimed by a later burst or crisis message, never sent (#391's
  dispatch and crisis flows, S2/S3). The existing check constraint
  (`20261006040546_add_delivery_state_to_messages.exs:30-34`) is
  dropped and recreated to include it.

  `up` backfills every pre-existing inbound row with
  `replied_by_message_id = id` (design AD2, a self-reference): this
  marks the row "legacy, outside the burst model" without a sentinel
  UUID or a second boolean column. A self-reference can never equal a
  reply's id (the release predicate) or appear in the pending-reply
  subquery (the absorb predicate), so it is excluded from every burst
  query exactly like a genuinely covered row (R10). The backfill SQL
  lives in `Alethea.Clinical.BurstBackfill.sql/0` (not on this module)
  because migration files are not loaded by `mix test`'s normal
  compile step — see that module's doc for why, and
  `test/alethea/migrations/burst_coverage_test.exs` for how it is
  exercised directly against sandboxed test rows.

  `down` restores the 5-state check constraint. It fails while any
  `superseded` row exists — map those to `failed` first, or keep the
  column, before rolling back.
  """

  use Ecto.Migration

  alias Alethea.Clinical.BurstBackfill

  @old_delivery_state_check "delivery_state IS NULL OR delivery_state IN " <>
                              "('pending', 'sending', 'sent', 'ambiguous', 'failed')"

  @new_delivery_state_check "delivery_state IS NULL OR delivery_state IN " <>
                              "('pending', 'sending', 'sent', 'ambiguous', 'failed', 'superseded')"

  def up do
    alter table(:messages) do
      add :replied_by_message_id, references(:messages, type: :binary_id, on_delete: :nothing)
    end

    create index(:messages, [:patient_id],
             where: "direction = 'inbound' AND replied_by_message_id IS NULL",
             name: :messages_uncovered_inbound_index
           )

    create index(:messages, [:replied_by_message_id],
             where: "replied_by_message_id IS NOT NULL",
             name: :messages_replied_by_message_id_index
           )

    drop constraint(:messages, :messages_delivery_state_check)

    create constraint(:messages, :messages_delivery_state_check, check: @new_delivery_state_check)

    execute(BurstBackfill.sql())
  end

  def down do
    drop constraint(:messages, :messages_delivery_state_check)

    create constraint(:messages, :messages_delivery_state_check, check: @old_delivery_state_check)

    drop index(:messages, [:replied_by_message_id], name: :messages_replied_by_message_id_index)

    drop index(:messages, [:patient_id], name: :messages_uncovered_inbound_index)

    alter table(:messages) do
      remove :replied_by_message_id
    end
  end
end
