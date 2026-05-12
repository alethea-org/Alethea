defmodule Alethea.Accounts.AuditLog do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "audit_logs" do
    field :action, :string
    field :resource_type, :string
    field :resource_id, :binary_id
    field :details, :map, default: %{}
    field :ip_address, :string
    field :user_agent, :string

    belongs_to :professional, Alethea.Accounts.Professional

    timestamps(type: :utc_datetime)
  end

  def changeset(audit_log, attrs) do
    audit_log
    |> cast(attrs, [
      :action,
      :resource_type,
      :resource_id,
      :details,
      :ip_address,
      :user_agent,
      :professional_id
    ])
    |> validate_required([:action, :resource_type, :professional_id])
  end
end
