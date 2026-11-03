defmodule Alethea.Repo.Migrations.AllowUnapprovedTriggers do
  use Ecto.Migration

  def up do
    alter table(:triggers) do
      modify :approved_text, :binary, null: true, from: {:binary, null: false}
      modify :draft_message, :binary, null: true, from: {:binary, null: false}
    end
  end

  def down do
    alter table(:triggers) do
      modify :draft_message, :binary, null: false, from: {:binary, null: true}
      modify :approved_text, :binary, null: false, from: {:binary, null: true}
    end
  end
end
