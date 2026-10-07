defmodule Alethea.Clinical.BurstRepair do
  @moduledoc """
  The raw SQL that repairs `replied_by_message_id` for inbound Telegram
  rows saved between S1's backfill and S3's activation of the burst
  worker (#391, design AD2's "S3 adds a repair pass").

  Those rows are still `NULL` (S1's backfill only ran once, against the
  rows that existed at that moment; S2 shipped the burst worker inert,
  so nothing covered any row written after S1 and before this
  migration runs). Some of them already have a genuine reply — the
  OLD, still-synchronous safe path (`persist_and_enqueue_outbound/7`,
  removed in S3) linked the reply to its inbound via
  `reply_to_message_id` (#390), the opposite direction from coverage.
  This repair reads that link where it exists and sets coverage to
  match; a row with no reply at all (dropped, unregistered, or any
  other gap) gets the same self-reference marker the original backfill
  used (design AD2) — "legacy, outside the burst model".

  Lives under `lib/` for the same reason as `Alethea.Clinical.BurstBackfill`:
  migration files are not loaded by `mix test`'s normal compile step, so
  the SQL is exposed here and called from both the migration's `up/0`
  and `test/alethea/migrations/burst_coverage_test.exs`.
  """

  @sql """
  UPDATE messages m
  SET replied_by_message_id = COALESCE(
    (SELECT r.id FROM messages r
       WHERE r.reply_to_message_id = m.id AND r.direction = 'outbound'
       LIMIT 1),
    m.id
  )
  WHERE m.direction = 'inbound' AND m.replied_by_message_id IS NULL
  """

  @spec sql() :: String.t()
  def sql, do: @sql
end
