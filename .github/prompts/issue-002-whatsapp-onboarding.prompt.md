---
description: "Issue 002 — Onboarding de WhatsApp y flujo de consentimiento legal"
---

# Issue 002: Onboarding de WhatsApp y Consentimiento

Implementa el flujo de primer contacto del paciente via WhatsApp: bloqueo de
procesamiento clínico hasta que el paciente acepte los términos de privacidad.

## Contexto

- **Bloqueado por**: Issue 001 (paciente debe existir en la BD)
- **User Story**: 4 (consentimiento legal antes del primer uso)
- **Módulos clave**: `AletheaJobs.ProcessMessageWorker`, `Alethea.Accounts.Patient`

## Tareas a Implementar

### 1. Migración: campo `terms_accepted`

```bash
mix ecto.gen.migration add_terms_accepted_to_patients
```

```elixir
def change do
  alter table(:patients) do
    add :terms_accepted, :boolean, default: false, null: false
  end
end
```

### 2. Actualización del Schema

Añadir `terms_accepted` al schema de `Patient` (campo solo setteable internamente,
NO en el changeset público de `cast`).

### 3. Lógica en `ProcessMessageWorker`

```elixir
def perform(%Oban.Job{args: %{"patient_id" => patient_id, "message" => _message}}) do
  patient = Alethea.Accounts.get_patient!(patient_id)

  if patient.terms_accepted do
    # Continuar con procesamiento de IA
    enqueue_ai_processing(patient_id, message)
  else
    # Primer contacto: enviar mensaje de consentimiento interactivo
    send_consent_message(patient)
  end
end

defp send_consent_message(patient) do
  terms_text = """
  Bienvenido/a a Alethea. Antes de continuar, necesitamos tu consentimiento:

  • Tus mensajes son procesados por IA para apoyo emocional.
  • Los datos se cifran y solo tu terapeuta tiene acceso.
  • Esto NO reemplaza la atención psicológica profesional.
  • En caso de crisis, serás dirigido a líneas de ayuda humana.

  Responde *ACEPTO* para continuar.
  """
  Alethea.WhatsApp.Client.send_text_message(patient.whatsapp_number, terms_text)
end
```

### 4. Manejador de Respuesta "ACEPTO"

En el webhook o `ProcessMessageWorker`, detectar si el mensaje es "ACEPTO":

```elixir
defp handle_consent_response(%{terms_accepted: false} = patient, "ACEPTO") do
  Alethea.Accounts.accept_terms(patient)
  Alethea.WhatsApp.Client.send_text_message(
    patient.whatsapp_number,
    "¡Gracias! Estás listo/a para comenzar tu diario emocional con Alethea."
  )
end
```

### 5. Función `accept_terms/1` en `Alethea.Accounts`

```elixir
def accept_terms(%Patient{} = patient) do
  patient
  |> Ecto.Changeset.change(terms_accepted: true)
  |> Repo.update()
end
```

## Tests

- Verificar que mensajes clínicos NO se procesan si `terms_accepted: false`
- Verificar que el mensaje de consentimiento se envía al primer contacto
- Verificar que `accept_terms/1` cambia el estado correctamente
- Mockear `Alethea.WhatsApp.Client` con `Mox` o `Req.Test`

## Checklist

- [ ] Migración añade `terms_accepted` (default: false)
- [ ] `ProcessMessageWorker` bloquea procesamiento clínico si `terms_accepted: false`
- [ ] Mensaje de consentimiento claro y preciso enviado al primer contacto
- [ ] Manejador procesa correctamente la respuesta "ACEPTO"
- [ ] `accept_terms/1` actualiza el campo en la BD
- [ ] Ningún mensaje clínico se guarda antes de la aceptación
- [ ] `mix precommit` pasa limpio
