defmodule Alethea.Clinical.BurstBackfill do
  @moduledoc """
  The raw SQL that marks pre-#391 inbound Telegram messages as
  "legacy, outside the burst model" (design AD2): a self-reference,
  `replied_by_message_id = id`.

  Lives under `lib/` — not inside the migration file under
  `priv/repo/migrations/` — so it compiles with the rest of the
  application and stays directly callable from tests. Migration files
  are loaded only by the Ecto Mix tasks (`ecto.migrate`, `ecto.rollback`),
  not by `mix test`'s normal compile step, so a function defined on the
  migration module itself is unavailable at test runtime (tasks.md
  Phase 2 flagged this choice: sandboxed `Ecto.Migrator` re-execution
  was impractical, so the SQL is exposed here instead).

  `priv/repo/migrations/20261007185102_add_burst_coverage_to_messages.exs`
  calls `sql/0` to run this exact statement inside its own `up/0`.
  `test/alethea/migrations/burst_coverage_test.exs` calls it directly
  against sandboxed rows to prove the self-reference marker — not the
  specific moment it is applied — is what excludes a row from a burst
  (R10).
  """

  @sql "UPDATE messages SET replied_by_message_id = id WHERE direction = 'inbound'"

  @spec sql() :: String.t()
  def sql, do: @sql
end
