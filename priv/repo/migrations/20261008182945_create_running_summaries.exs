defmodule Alethea.Repo.Migrations.CreateRunningSummaries do
  use Ecto.Migration

  # GitHub #394 - protected factual running summary (one row per patient).
  #
  # The composite FK `(patient_id, professional_id) -> patients (id,
  # professional_id)` makes a cross-tenant row impossible at the database
  # level (writes use `insert_all`/`update_all`, which skip changesets).
  # Postgres needs a unique index on the referenced columns; it is trivially
  # satisfied because `id` is already the patients primary key (same pattern
  # as #289). ON UPDATE keeps the default NO ACTION so reassigning a patient's
  # professional fails closed while a summary row exists.
  def change do
    create unique_index(:patients, [:id, :professional_id])

    create table(:running_summaries, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :patient_id,
          references(:patients,
            type: :binary_id,
            with: [professional_id: :professional_id],
            match: :full,
            on_delete: :delete_all
          ),
          null: false

      add :professional_id, :binary_id, null: false
      # Journaling "patient" DEK ciphertext. Never the clinical-record DEK.
      add :encrypted_summary, :binary, null: false
      add :encryption_version, :integer, null: false, default: 1
      add :covered_inbound_count, :integer, null: false

      add :covered_through_message_id,
          references(:messages, type: :binary_id, on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    create unique_index(:running_summaries, [:patient_id])

    create constraint(:running_summaries, :covered_inbound_count_positive,
             check: "covered_inbound_count > 0"
           )
  end
end
