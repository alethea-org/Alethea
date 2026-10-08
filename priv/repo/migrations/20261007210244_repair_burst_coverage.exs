defmodule Alethea.Repo.Migrations.RepairBurstCoverage do
  @moduledoc """
  Repairs `replied_by_message_id` for inbound Telegram rows saved
  between S1's backfill migration and this S3 activation of the burst
  worker (#391, design AD2).

  `up` links a row to its existing reply where one exists (via
  `reply_to_message_id`, #390's provenance column — the opposite
  direction from coverage), or self-references it exactly like the
  original backfill (design AD2, "legacy, outside the burst model")
  when no reply exists at all. See `Alethea.Clinical.BurstRepair`'s
  moduledoc for why the rows exist and why the SQL lives there instead
  of here.

  `down` is a no-op: this is a data repair, not a schema change, and
  nothing downstream distinguishes a repaired row from a genuinely
  covered one — there is no reversible state to restore.
  """

  use Ecto.Migration

  alias Alethea.Clinical.BurstRepair

  def up do
    execute(BurstRepair.sql())
  end

  def down do
    :ok
  end
end
