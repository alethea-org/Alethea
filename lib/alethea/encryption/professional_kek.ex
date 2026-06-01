defmodule Alethea.Encryption.ProfessionalKek do
  @moduledoc """
  Gestiona la generación, almacenamiento y carga de la KEK (Key Encryption Key)
  de un profesional.
  """

  import Ecto.Query

  alias Alethea.Repo
  alias Alethea.Accounts.EncryptionKey
  alias Alethea.Encryption.Vault

  @doc """
  Genera una nueva KEK aleatoria de 32 bytes.
  """
  def generate_kek do
    :crypto.strong_rand_bytes(32)
  end

  @doc """
  Cifra la KEK con el Vault global y la guarda en la base de datos.
  """
  def store_kek(professional, kek_bytes) do
    encrypted_kek = Vault.encrypt!(kek_bytes)

    %EncryptionKey{}
    |> EncryptionKey.changeset(%{
      professional_id: professional.id,
      encrypted_key: encrypted_kek,
      type: "professional"
    })
    |> Repo.insert()
  end

  @doc """
  Carga y descifra la KEK de un profesional desde la base de datos.
  """
  def load_kek(professional) do
    case Repo.get_by(EncryptionKey, professional_id: professional.id, type: "professional") do
      nil ->
        {:error, :not_found}

      key_record ->
        kek = Vault.decrypt!(key_record.encrypted_key)

        # Auditoría: Carga de llave maestra del profesional
        Alethea.Accounts.log_action(%{
          professional_id: professional.id,
          action: "KEK_LOAD",
          resource_type: "EncryptionKey",
          resource_id: key_record.id,
          details: %{reason: "session_auth_or_job_processing"}
        })

        {:ok, kek}
    end
  end

  @doc """
  Verifica que existe una KEK en la base de datos para el profesional dado.
  Retorna {:ok, key_id} si existe, {:error, :not_found} si no.
  """
  def kek_exists?(professional_id) do
    case Repo.one(
           from(k in EncryptionKey,
             where: k.professional_id == ^professional_id and k.type == "professional"
           )
         ) do
      nil -> {:error, :not_found}
      key -> {:ok, key.id}
    end
  rescue
    # Handle case where multiple keys exist (shouldn't happen but be safe)
    Ecto.MultipleResultsError ->
      {:error, :multiple_keys_found}
  end
end
