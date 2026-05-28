---
description: >
  Referencias técnicas curadas para implementar cifrado seguro en Alethea:
  Cloak.Ecto, envelope encryption, HMAC para búsquedas y Cryptographic Erasure.
---

# Referencias: Encryption Vault — Alethea

## Documentación Oficial

- **Cloak.Ecto**: https://hexdocs.pm/cloak_ecto/
- **Cloak** (core): https://hexdocs.pm/cloak/
- **Ecto.Multi**: https://hexdocs.pm/ecto/Ecto.Multi.html

## API Reference Rápida — Cloak.Ecto

### Tipos de Campo

| Tipo Cloak              | Uso en Alethea                          |
|-------------------------|-----------------------------------------|
| `Cloak.Ecto.Binary`     | WhatsApp, notas clínicas, datos sensibles|
| `Cloak.Ecto.SHA256`     | Hashes de verificación (no búsqueda)    |

### Configuración del Vault

```elixir
# lib/alethea/encryption/vault.ex
defmodule Alethea.Encryption.Vault do
  use Cloak.Vault, otp_app: :alethea

  @impl GenServer
  def init(config) do
    config =
      Keyword.put(config, :ciphers,
        default: {
          Cloak.Ciphers.AES.GCM,
          tag: "AES.GCM.V1",
          key: Base.decode64!(System.fetch_env!("CLOAK_KEY")),
          iv_length: 12
        }
      )
    {:ok, config}
  end
end
```

```elixir
# config/config.exs
config :alethea, Alethea.Encryption.Vault,
  json_library: Jason
```

### Schema con Campos Cifrados

```elixir
schema "patients" do
  field :alias,                :string           # No sensible, texto plano
  field :whatsapp_number,      Cloak.Ecto.Binary  # PII: cifrado
  field :whatsapp_number_hash, :string            # HMAC para búsqueda
end
```

### Setear Campos Cifrados Programáticamente

```elixir
# NUNCA en cast(). Siempre programáticamente en la lógica de negocio:
defp put_encrypted_phone(changeset, phone, psychologist_id) do
  changeset
  |> Ecto.Changeset.put_change(:whatsapp_number, phone)
  |> Ecto.Changeset.put_change(
      :whatsapp_number_hash,
      compute_hmac(phone, psychologist_id)
    )
end

defp compute_hmac(value, salt) do
  :crypto.mac(:hmac, :sha256, salt, value) |> Base.encode16(case: :lower)
end
```

## Envelope Encryption (DEK/KEK)

### Conceptos

```
KEK (Key Encryption Key): Llave del profesional. Protege las DEKs.
DEK (Data Encryption Key): Llave única por paciente. Cifra sus datos.

Flujo de cifrado:
  1. Generar DEK aleatoria para el paciente
  2. Cifrar la DEK con la KEK del profesional
  3. Almacenar DEK_cifrada en encryption_keys
  4. Usar la DEK para cifrar los campos sensibles del paciente

Flujo de descifrado:
  1. Obtener DEK_cifrada de encryption_keys
  2. Descifrar DEK con la KEK del profesional (autenticado)
  3. Usar DEK para descifrar los campos del paciente
```

### Generación de DEK

```elixir
def generate_patient_dek do
  dek = :crypto.strong_rand_bytes(32) |> Base.encode64()
  {:ok, dek}
end
```

### Almacenamiento de DEK Cifrada

```elixir
def store_patient_dek(patient_id, dek) do
  kek = get_current_kek()  # Llave del profesional autenticado
  encrypted_dek = Cloak.Ciphers.AES.GCM.encrypt(dek, kek)

  %EncryptionKey{}
  |> EncryptionKey.changeset(%{
    patient_id: patient_id,
    encrypted_dek: encrypted_dek,
    algorithm: "AES-256-GCM"
  })
  |> Repo.insert()
end
```

## Cryptographic Erasure

```elixir
def delete_patient_data(patient_id) do
  # 1. Destruir la DEK (los datos se vuelven irrecuperables)
  from(k in EncryptionKey, where: k.patient_id == ^patient_id)
  |> Repo.delete_all()

  # 2. Opcionalmente: mantener el registro del paciente (ya ilegible)
  # O hacer DELETE físico si se requiere cumplimiento GDPR completo
  :ok
end
```

## Patrones de Testing

### Test de Opacidad SQL

```elixir
test "datos del paciente son opacos via SQL directo" do
  {:ok, %{patient: patient}} = Accounts.create_patient(%{
    alias: "Test Patient",
    whatsapp_number: "+34600000000",
    psychologist_id: psychologist.id
  })

  # Consulta SQL directa — debe retornar binario cifrado, no el número
  %{rows: [[raw_value]]} = Repo.query!(
    "SELECT whatsapp_number FROM patients WHERE id = $1",
    [patient.id]
  )

  refute raw_value == "+34600000000"
  assert is_binary(raw_value)
end
```

### Test de Cryptographic Erasure

```elixir
test "datos son irrecuperables después de destruir la DEK" do
  {:ok, %{patient: patient}} = Accounts.create_patient(valid_attrs())

  # Destruir la llave
  Encryption.KeyManager.invalidate_patient_dek(patient.id)

  # Intentar descifrar debe fallar
  assert {:error, :key_not_found} = Accounts.decrypt_patient_data(patient.id)
end
```

## Configuración de Entorno

```bash
# Generar CLOAK_KEY
mix cloak.generate_key

# .env (no commitear)
CLOAK_KEY=<base64 key de 32 bytes>
```
