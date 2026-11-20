defmodule Alethea.Waitlist.Entry do
  @moduledoc """
  A professional who asked to be told when Alethea launches, from the
  public landing's waitlist form. The email is stored trimmed and
  lowercased so the same person signs up once.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "waitlist_entries" do
    field :name, :string
    field :email, :string

    timestamps(type: :utc_datetime)
  end

  @email_format ~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/

  def changeset(entry, attrs) do
    entry
    |> cast(attrs, [:name, :email])
    |> update_change(:name, &String.trim/1)
    |> update_change(:email, &(&1 |> String.trim() |> String.downcase()))
    |> validate_required([:name], message: "Contanos tu nombre")
    |> validate_required([:email], message: "Necesitamos tu email")
    |> validate_length(:name, max: 120, message: "Usá hasta 120 caracteres")
    |> validate_length(:email, max: 160, message: "Usá hasta 160 caracteres")
    |> validate_format(:email, @email_format, message: "Revisá el email")
    |> unique_constraint(:email)
  end
end
