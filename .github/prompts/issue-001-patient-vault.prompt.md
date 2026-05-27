---
description: "Issue 001 — Implementar registro de pacientes con bóveda segura y envelope encryption"
---

# Issue 001: Registro de Pacientes y Bóveda Segura

Implementa el flujo completo de registro de pacientes con cifrado por paciente.
Sigue el esquema de envelope encryption de `lib/alethea/DER.md` y `lib/alethea/accounts/CONTEXT.md`.

## Contexto

- **Bloqueado por**: Nada (primer issue del roadmap)
- **User Stories**: 1 (registro por psicólogo) y 8 (cifrado por paciente)
- **Módulos clave**: `Alethea.Accounts`, `Alethea.Encryption.Vault`, `PatientLive.Index`

## Tareas a Implementar

### 1. LiveView de Registro

Finaliza `AletheaWeb.PatientLive.Index` para incluir un modal de creación de paciente:
- Formulario con campos: alias, número de WhatsApp
- El formulario usa `to_form/2` derivado de changeset
- ID único en el formulario: `id="new-patient-form"`

### 2. Función `create_patient/1` en `Alethea.Accounts`

```elixir
def create_patient(attrs) do
  Ecto.Multi.new()
  |> Ecto.Multi.run(:dek, fn _repo, _ ->
    Alethea.Encryption.KeyManager.generate_patient_dek()
  end)
  |> Ecto.Multi.insert(:patient, fn %{dek: dek} ->
    # Cifrar whatsapp_number con la DEK
    # Calcular whatsapp_number_hash (HMAC por psychologist_id)
  end)
  |> Ecto.Multi.run(:store_dek, fn _repo, %{patient: patient, dek: dek} ->
    Alethea.Encryption.KeyManager.store_patient_dek(patient.id, dek)
  end)
  |> Repo.transaction()
end
```

### 3. Schema `Patient`

Asegura que `patients` tenga:
- `whatsapp_number` como `Cloak.Ecto.Binary`
- `whatsapp_number_hash` como `:string` (para búsquedas)
- `terms_accepted` como `:boolean, default: false`
- `urgent_intervention` como `:boolean, default: false`

### 4. Tests de Integración

En `test/alethea/accounts_test.exs`:

```elixir
test "datos del paciente son ilegibles via SQL directo" do
  {:ok, %{patient: patient}} = Accounts.create_patient(valid_attrs())
  raw = Repo.query!("SELECT whatsapp_number FROM patients WHERE id = $1", [patient.id])
  refute List.first(raw.rows) |> List.first() == valid_attrs().whatsapp_number
end

test "cryptographic erasure al invalidar la DEK" do
  {:ok, %{patient: patient}} = Accounts.create_patient(valid_attrs())
  Encryption.KeyManager.invalidate_patient_dek(patient.id)
  assert {:error, :key_not_found} = Accounts.decrypt_patient_data(patient.id)
end
```

## Checklist

- [ ] Modal de creación en `PatientLive.Index` con `id="new-patient-form"`
- [ ] `create_patient/1` usa `Ecto.Multi` atómico
- [ ] `whatsapp_number` cifrado con `Cloak.Ecto.Binary`
- [ ] `whatsapp_number_hash` es HMAC salado por `psychologist_id`
- [ ] Test verifica opacidad SQL
- [ ] Test verifica Cryptographic Erasure
- [ ] `mix precommit` pasa limpio
