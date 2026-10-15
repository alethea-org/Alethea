defmodule Alethea.Repo.Migrations.InvalidateRunningSummariesForCrisisRule do
  use Ecto.Migration

  @moduledoc """
  #399: crisis exchanges are no longer part of the summarized
  population (they collapse into one neutral placeholder turn and their
  trigger inbounds leave the cadence count), so every running summary
  written under the previous rule covers a population that no longer
  exists. Invalidated here; the next batches rebuild them automatically
  (`Alethea.Clinical.RunningSummary.plan/1`), bounded by the summary
  window cap as the issue's acceptance criteria accept.
  """

  def up do
    execute("DELETE FROM running_summaries")
  end

  # Data deletion: nothing to restore. Rows rebuild automatically.
  def down, do: :ok
end
