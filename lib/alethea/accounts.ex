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

  def lookup_patient_by_phone(phone_e164) do
    hash =
      :crypto.mac(:hmac, :sha256, Application.fetch_env!(:alethea, :phone_hash_secret), phone_e164)
      |> Base.encode64()

    case Repo.get_by(Patient, whatsapp_number_hash: hash) do
      nil -> {:error, :not_found}
      patient -> {:ok, patient}
    end
  end

  def update_patient_terms(%Patient{} = patient, accepted?) do
    patient
    |> Patient.changeset(%{terms_accepted: accepted?})
    |> Repo.update()
  end

  def create_patient(attrs \\ %{}) do
    %Patient{}
    |> Patient.changeset(attrs)
    |> Repo.insert()
  end
end
