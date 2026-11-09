defmodule Alethea.Repo.Migrations.AddArchivedAtToTriggers do
  use Ecto.Migration

  # Professional-facing "delete": an archived trigger is hidden from listings
  # and never fires again, while its row (and the firings and messages that
  # point to it) stays as clinical/audit history.
  def change do
    alter table(:triggers) do
      add :archived_at, :utc_datetime
    end
  end
end
