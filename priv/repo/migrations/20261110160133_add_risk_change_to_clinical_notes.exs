defmodule Alethea.Repo.Migrations.AddRiskChangeToClinicalNotes do
  use Ecto.Migration

  # A clinical note can record that the professional activated or
  # deactivated the patient's risk (urgent intervention) flag. The value
  # is written once at insert time; the existing BEFORE UPDATE trigger
  # keeps the row immutable. Nullable: existing notes changed nothing.
  def change do
    alter table(:clinical_notes) do
      add :risk_change, :string
    end

    create constraint(:clinical_notes, :clinical_notes_risk_change_valid,
             check: "risk_change IS NULL OR risk_change IN ('activated', 'deactivated')"
           )
  end
end
