defmodule Alethea.Accounts do
  @moduledoc """
  The Accounts context.
  """

  import Ecto.Query, warn: false
  alias Alethea.Repo
  alias Alethea.Accounts.{Professional, Patient, EncryptionKey}
  alias Alethea.Encryption.{PatientVault, ProfessionalKek}

  # Professionals

  def list_professionals do
    Repo.all(Professional)
  end

  def get_professional!(id), do: Repo.get!(Professional, id)

  def get_professional_by_email(email) when is_binary(email) do
    Repo.get_by(Professional, email: email)
  end

  def create_professional(attrs \\ %{}) do
    Repo.transaction(fn ->
      with {:ok, professional} <- %Professional{} |> Professional.changeset(attrs) |> Repo.insert(),
           kek_bytes = ProfessionalKek.generate_kek(),
           {:ok, _key} <- ProfessionalKek.store_kek(professional, kek_bytes) do
        professional
      else
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
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

  def load_professional_kek(professional) do
    ProfessionalKek.load_kek(professional)
  end

  # Patients

  def list_patients(professional_id) do
    Patient
    |> where([p], p.professional_id == ^professional_id)
    |> where([p], p.status != "deleted")
    |> order_by([p], desc: p.urgent_intervention, asc: p.alias)
    |> Repo.all()
  end

  def list_critical_patients(professional_id) do
    Patient
    |> where([p], p.professional_id == ^professional_id)
    |> where([p], p.status != "deleted")
    |> where([p], p.urgent_intervention == true)
    |> order_by([p], asc: p.alias)
    |> Repo.all()
  end

  def get_patient_for_professional(professional_id, patient_id) do
    Patient
    |> where([p], p.id == ^patient_id)
    |> where([p], p.professional_id == ^professional_id)
    |> where([p], p.status != "deleted")
    |> Repo.one()
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

  def update_patient_session_schedule(%Patient{} = patient, day, time) do
    patient
    |> Patient.changeset(%{session_day_of_week: day, session_time: time})
    |> Repo.update()
  end

  def create_audit_log(attrs \\ %{}) do
    %Alethea.Accounts.AuditLog{}
    |> Alethea.Accounts.AuditLog.changeset(attrs)
    |> Repo.insert()
  end

  def get_encryption_key_for_patient(patient_id) do
    EncryptionKey
    |> where([k], k.patient_id == ^patient_id and k.type == "patient")
    |> Repo.one()
  end

  @doc """
  Crea un paciente con cifrado de extremo a extremo.
  Genera una DEK única, la envuelve con la KEK del profesional y cifra el número de WhatsApp.
  """
  def create_patient(attrs, kek_bytes) when is_binary(kek_bytes) do
    # Normalizar attrs a string keys para evitar mixed keys
    attrs = for {k, v} <- attrs, into: %{}, do: {to_string(k), v}
    whatsapp_number = attrs["whatsapp_number"]

    # 1. Generar DEK
    dek_bytes = :crypto.strong_rand_bytes(32)

    # 2. Cifrar DEK con KEK
    {:ok, wrapped_dek} = PatientVault.encrypt(dek_bytes, kek_bytes)

    # 3. Cifrar número con DEK
    {:ok, encrypted_number} = PatientVault.encrypt(whatsapp_number, dek_bytes)

    # 4. Calcular hash determinista
    phone_hash =
      :crypto.mac(:hmac, :sha256, Application.fetch_env!(:alethea, :phone_hash_secret), whatsapp_number)
      |> Base.encode64()

    Ecto.Multi.new()
    |> Ecto.Multi.insert(:encryption_key, EncryptionKey.changeset(%EncryptionKey{}, %{
      "encrypted_key" => wrapped_dek,
      "type" => "patient"
    }))
    |> Ecto.Multi.insert(:patient, fn %{encryption_key: key} ->
      attrs_with_security =
        attrs
        |> Map.put("encrypted_whatsapp_number", encrypted_number)
        |> Map.put("whatsapp_number_hash", phone_hash)
        |> Map.put("encryption_key_id", key.id)

      %Patient{} |> Patient.changeset(attrs_with_security)
    end)
    |> Ecto.Multi.update(:finalize_key, fn %{patient: patient, encryption_key: key} ->
      EncryptionKey.changeset(key, %{patient_id: patient.id})
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{patient: patient}} -> {:ok, patient}
      {:error, _name, error, _changes} -> {:error, error}
    end
  end

  # Fallback para tests antiguos o creación sin KEK (deprecated)
  def create_patient(attrs) do
    %Patient{}
    |> Patient.changeset(attrs)
    |> Repo.insert()
  end
end
