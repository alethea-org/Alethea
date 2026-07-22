defmodule Alethea.AI.Diagnosis do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  # PHI hygiene: `ai_response` and `extracted_emotions` carry plaintext clinical
  # content. Two inspect shapes must be covered:
  #   * `field ..., redact: true` redacts them from `%Ecto.Changeset{}` inspect
  #     (the `changes` map) — the shape surfaced during error handling, e.g. the
  #     Telegram worker's persistence-failure path. `@derive` does NOT cover this;
  #     only `redact: true` populates `__schema__(:redact_fields)`.
  #   * `@derive {Inspect, except: ...}` redacts them from bare `%Diagnosis{}`
  #     struct inspect.
  @derive {Inspect, except: [:ai_response, :extracted_emotions]}
  schema "ai_diagnoses" do
    field :model_version, :string
    field :extracted_emotions, :map, redact: true
    field :ai_response, :string, redact: true

    belongs_to :message, Alethea.Clinical.Message

    timestamps(type: :utc_datetime)
  end

  def changeset(diagnosis, attrs) do
    diagnosis
    |> cast(attrs, [:model_version, :extracted_emotions, :ai_response, :message_id])
    |> validate_required([:model_version, :extracted_emotions, :ai_response, :message_id])
  end
end
