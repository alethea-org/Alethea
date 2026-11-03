defmodule Alethea.Repo.Migrations.AddTriggerApprovalRevision do
  use Ecto.Migration

  def change do
    alter table(:triggers) do
      add :approval_revision, :integer, null: false, default: 1
    end
  end
end
