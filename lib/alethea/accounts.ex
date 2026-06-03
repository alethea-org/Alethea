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
      with {:ok, professional} <-
             %Professional{} |> Professional.changeset(attrs) |> Repo.insert(),
           kek_bytes = ProfessionalKek.generate_kek(),
           {:ok, _key} <- ProfessionalKek.store_kek(professional, kek_bytes) do
        professional
      else
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
  end

  @doc """
  Registra una acción en el log de auditoría.
  """
  def log_action(attrs) do
    %Alethea.Accounts.AuditLog{}
    |> Alethea.Accounts.AuditLog.changeset(attrs)
    |> Repo.insert()
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

  def load_patient_dek(patient, professional_kek) when is_binary(professional_kek) do
    case Repo.get_by(EncryptionKey, patient_id: patient.id, type: "patient") do
      nil ->
        {:error, :not_found}

      key_record ->
        PatientVault.decrypt(key_record.encrypted_key, professional_kek)
    end
  end

  def update_professional(%Professional{} = professional, attrs) do
    professional
    |> Professional.changeset(attrs)
    |> Repo.update()
  end

  # Patients

  def list_patients(professional_id) do
    Patient
    |> where([p], p.professional_id == ^professional_id)
    |> where([p], p.status != "deleted")
    |> order_by([p], desc: p.urgent_intervention, asc: p.alias)
    |> Repo.all()
  end

  def get_patient_with_professional(patient_id) do
    Patient
    |> where([p], p.id == ^patient_id)
    |> preload([:professional])
    |> Repo.one()
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

  def lookup_patient_by_phone(phone) do
    normalized = normalize_phone(phone)

    hash =
      :crypto.mac(
        :hmac,
        :sha256,
        Application.fetch_env!(:alethea, :phone_hash_secret),
        normalized
      )
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

  def update_patient(%Patient{} = patient, attrs) when is_map(attrs) do
    allowed_attrs =
      Map.take(attrs, [
        :urgent_intervention,
        :terms_accepted,
        :status,
        :session_day_of_week,
        :session_time
      ])

    patient
    |> Patient.changeset(allowed_attrs)
    |> Repo.update()
  end

  @doc """
  Archives a patient (soft delete). Sets status to "archived".
  """
  def archive_patient(%Patient{} = patient) do
    patient
    |> Patient.changeset(%{status: "archived"})
    |> Repo.update()
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

    cond do
      is_nil(whatsapp_number) or not is_binary(whatsapp_number) or
          String.trim(whatsapp_number) == "" ->
        changeset =
          %Patient{}
          |> Patient.changeset(attrs)
          |> Ecto.Changeset.add_error(:whatsapp_number, "can't be blank")

        {:error, %{changeset | action: :insert}}

      true ->
        # Normalizar número de teléfono a E.164
        normalized_number = normalize_phone(whatsapp_number)

        # 1. Generar DEK
        dek_bytes = :crypto.strong_rand_bytes(32)

        # 2. Cifrar DEK con KEK
        {:ok, wrapped_dek} = PatientVault.encrypt(dek_bytes, kek_bytes)

        # 3. Cifrar número con DEK
        {:ok, encrypted_number} = PatientVault.encrypt(normalized_number, dek_bytes)

        # 4. Calcular hash determinista
        phone_hash =
          :crypto.mac(
            :hmac,
            :sha256,
            Application.fetch_env!(:alethea, :phone_hash_secret),
            normalized_number
          )
          |> Base.encode64()

        # Insert encryption key with placeholder patient_id
        # After patient is created, we update with the real patient_id
        # This is ACID-safe within the transaction - the key cannot be accessed
        # externally until patient_id is set, and if anything fails, both roll back
        Ecto.Multi.new()
        |> Ecto.Multi.insert(
          :encryption_key,
          EncryptionKey.changeset(%EncryptionKey{}, %{
            "encrypted_key" => wrapped_dek,
            "type" => "patient"
          })
        )
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
          {:ok, %{patient: patient}} ->
            # Notificar a los LiveViews del profesional
            Phoenix.PubSub.broadcast(
              Alethea.PubSub,
              "patients:#{patient.professional_id}",
              {:patient_created, patient}
            )

            log_action(%{
              professional_id: patient.professional_id,
              action: "CREATE_PATIENT",
              resource_type: "Patient",
              resource_id: patient.id,
              details: %{alias: patient.alias}
            })

            {:ok, patient}

          {:error, _name, error, _changes} ->
            {:error, error}
        end
    end
  end

  # Fallback para tests antiguos o creación sin KEK (deprecated)
  def create_patient(attrs) do
    %Patient{}
    |> Patient.changeset(attrs)
    |> Repo.insert()
  end

  defp normalize_phone(phone) when is_binary(phone) do
    phone
    |> String.replace(~r/[^\d+]/, "")
    |> then(fn
      "+" <> _ = phone -> phone
      phone -> "+" <> phone
    end)
  end
end
