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

  def get_professional_by_email(email) when is_binary(email) do
    Repo.get_by(Professional, email: email)
  end

  def authenticate_professional(email, password)
      when is_binary(email) and is_binary(password) do
    case get_professional_by_email(email) do
      %Professional{password_hash: hash} = professional ->
        if Pbkdf2.verify_pass(password, hash) do
          {:ok, professional}
        else
          {:error, :invalid_credentials}
        end

      nil ->
        Pbkdf2.no_user_verify()
        {:error, :invalid_credentials}
    end
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
