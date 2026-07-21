defmodule Alethea.AI.Diagnosis do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  # PHI hygiene: `ai_response` and `extracted_emotions` carry plaintext
  # clinical content. `@derive` excludes them from `inspect/1` so no
  # inspect site (logs, IEx, error messages, e.g. the Telegram worker's
  # persistence-failure raise) can leak them.
  @derive {Inspect, except: [:ai_response, :extracted_emotions]}
  schema "ai_diagnoses" do
    field :model_version, :string
    field :extracted_emotions, :map
    field :ai_response, :string

    belongs_to :message, Alethea.Clinical.Message

    timestamps(type: :utc_datetime)
  end

  def changeset(diagnosis, attrs) do
    diagnosis
    |> cast(attrs, [:model_version, :extracted_emotions, :ai_response, :message_id])
    |> validate_required([:model_version, :extracted_emotions, :ai_response, :message_id])
  end
end
