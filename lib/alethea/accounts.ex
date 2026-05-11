defmodule Alethea.Accounts do
  @moduledoc """
  The Accounts context.
  """

  import Ecto.Query, warn: false
  alias Alethea.Repo
  alias Alethea.Accounts.{Professional, Patient}

  # Professionals

  def list_professionals do
    Repo.all(Professional)
  end

  def get_professional!(id), do: Repo.get!(Professional, id)

  def create_professional(attrs \\ %{}) do
    %Professional{}
    |> Professional.changeset(attrs)
    |> Repo.insert()
  end

  # Patients

  def list_patients(professional_id) do
    Patient
    |> where(professional_id: ^professional_id)
    |> Repo.all()
  end

  def get_patient!(id), do: Repo.get!(Patient, id)

  def create_patient(attrs \\ %{}) do
    %Patient{}
    |> Patient.changeset(attrs)
    |> Repo.insert()
  end
end
