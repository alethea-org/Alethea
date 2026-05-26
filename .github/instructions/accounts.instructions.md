---
applyTo: "lib/alethea/accounts/**"
---

# Instrucciones: Módulo Accounts (Pacientes y Cifrado)

Estas instrucciones aplican a todos los archivos dentro de `lib/alethea/accounts/`.

## Reglas de Seguridad (OBLIGATORIAS)

- **NUNCA** almacenes campos PII (número de WhatsApp, notas, alias médico) en texto plano.
  Usa siempre `Cloak.Ecto.Binary` para campos cifrados.
- **NUNCA** hagas búsquedas de pacientes por número de WhatsApp en claro.
  Usa `whatsapp_number_hash` (HMAC salado por `psychologist_id`) para lookup.
- **NUNCA** expongas el `patient_id` en logs o traces externos.
- Las llaves de datos (DEK) de cada paciente viven en `encryption_keys`, nunca en el mismo
  registro del paciente.

## Cifrado con Cloak.Ecto

```elixir
# SIEMPRE usa Cloak.Ecto.Binary para campos sensibles
field :whatsapp_number, Cloak.Ecto.Binary

# SIEMPRE usa hash para búsquedas (no el campo cifrado)
field :whatsapp_number_hash, :string
```

## Transacciones Atómicas

- Toda operación que involucre creación de paciente + generación/almacenamiento de llave
  DEBE usar `Ecto.Multi` / `Repo.transaction/1`.
- Si la generación de la DEK falla, la inserción del paciente debe revertirse.

## Borrado Criptográfico

- "Borrar" un paciente significa invalidar/destruir su DEK en `encryption_keys`.
- Los registros en `patients` pueden permanecer; sin la DEK son ilegibles.
- Nunca hagas `DELETE` físico de datos clínicos sin destruir primero la llave.

## Schema Pattern

```elixir
defmodule Alethea.Accounts.Patient do
  use Ecto.Schema
  import Ecto.Changeset

  schema "patients" do
    field :alias,                 :string
    field :whatsapp_number,       Cloak.Ecto.Binary
    field :whatsapp_number_hash,  :string
    field :terms_accepted,        :boolean, default: false
    field :urgent_intervention,   :boolean, default: false
    belongs_to :psychologist, Alethea.Accounts.Psychologist
    timestamps()
  end

  # Los campos derivados/calculados (hash, encrypted) NO van en cast por seguridad
  def changeset(patient, attrs) do
    patient
    |> cast(attrs, [:alias, :terms_accepted])
    |> validate_required([:alias])
  end
end
```
