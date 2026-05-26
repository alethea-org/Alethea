defmodule Alethea.Encryption.ProfessionalKek do
  @moduledoc """
  Gestiona la generación, almacenamiento y carga de la KEK (Key Encryption Key)
  de un profesional.
  """

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
        {:ok, Vault.decrypt!(key_record.encrypted_key)}
    end
  end
end
