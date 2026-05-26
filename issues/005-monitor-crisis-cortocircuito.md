# Issue 005: Monitor de Crisis y Cortocircuito (Bypass)

**Type**: AFK
**Blocked by**: None (Pure Function & PubSub Contract / Contract-Driven Development)
**User Stories Covered**: 7

## 🤝 Contrato de Paralelización (Contract-Driven Development)

Esta issue de seguridad perimetral se desacopla por completo del pipeline de IA y WhatsApp, permitiendo su desarrollo de forma 100% paralela desde el inicio.

### Contrato Funcional: `Alethea.Alerts.CrisisMonitor`
El monitor de crisis es un procesador de texto puro sin estado ni efectos secundarios:
```elixir
defmodule Alethea.Alerts.CrisisMonitor do
  @spec detect(String.t()) :: :safe | {:crisis, :immediate | :high | :low, list(String.t())}
  def detect(text) do
    # Lógica de escaneo con regex y categorización de niveles (:immediate, :high, :low)
  end
end
```

### Contrato del Canal PubSub y Evento de Alerta
Para notificar al Dashboard LiveView de manera reactiva, se define formalmente el canal y el formato del mensaje:
*   **Canal PubSub**: `"crisis:alerts"`
*   **Tuple del Evento**: `{:crisis_detected, patient_id, level, triggers}`
    *   `patient_id`: uuid / binary_id del paciente
    *   `level`: atom (`:immediate`, `:high`, `:low`)
    *   `triggers`: list(string) (ej. `["me quiero morir"]`)

Al diseñar esta funcionalidad como un contrato puro, el desarrollador del Dashboard LiveView (Issue 006) puede suscribirse inmediatamente a `"crisis:alerts"` y probar la recepción y los Toasts interactivos enviando broadcasts manuales desde la consola `iex`:
```elixir
Phoenix.PubSub.broadcast(
  Alethea.PubSub, 
  "crisis:alerts", 
  {:crisis_detected, "paciente-uuid-123", :high, ["quiero morir"]}
)
```
Esto elimina por completo la necesidad de tener listo el webhook de WhatsApp o el worker de Oban de la Issue 003 para poder programar y verificar la reactividad del dashboard clínico.

## Description

Implementar una capa de seguridad crítica que detecte riesgo clínico en el texto del paciente antes de cualquier procesamiento del LLM, y cortocircuite el pipeline respondiendo con un mensaje de soporte humano con latencia mínima.

## Decisiones de Diseño

| Decisión | Elección | Justificación |
|---|---|---|
| Punto de ejecución | Dentro de `ProcessMessageWorker`, antes de llamar a `PhiWorker` | Separa la lógica clínica de la capa web; el controlador solo recibe y encola |
| Patrones de riesgo | Lista de regex por nivel en `config/runtime.exs`, leída con `Application.get_env/2` | Ajustable sin recompilación (evaluado en runtime al iniciar la release); evita hardcodear terminología clínica en el código |
| Niveles de crisis | 3 niveles: `:low` (ideación pasiva), `:high` (ideación activa/plan), `:immediate` (emergencia inminente) | Granularidad clínica; cada nivel tiene su propio conjunto de patrones |
| Respuesta al paciente | Un solo mensaje de soporte predefinido para todos los niveles | El nivel se usa solo para la alerta al profesional; el paciente siempre recibe el mismo mensaje de contención |
| Persistencia al detectar crisis | Guardar mensaje inbound cifrado en DB + `Diagnosis` con `ai_response: nil` y `extracted_emotions: %{crisis: true, level: level}` | Trazabilidad completa (Source Anchoring del GEMINI.md); el dashboard puede ver el disparador |
| Marcado del paciente | `Accounts.update_patient(patient, %{urgent_intervention: true})` — campo ya existe desde issue 001 | Sin migración nueva; solo actualizar el booleano existente |
| Notificación al dashboard | `Phoenix.PubSub.broadcast(Alethea.PubSub, "crisis:alerts", {:crisis_detected, patient_id, level, triggers})` directamente en el worker | PubSub ya está en el supervision tree; el dashboard de issue 006 se suscribe a este topic |
| Tests | Tests de regresión unitarios puros sobre `CrisisMonitor.detect/1` — sin DB, Oban ni efectos secundarios | La función es pura por diseño; los tests son la red de seguridad ante cambios accidentales en los patrones |

## Flujo del Cortocircuito

```
ProcessMessageWorker.perform/1 (rama terms_accepted: true)
  ├── [NUEVO] CrisisMonitor.detect(texto_entrante)
  │     ├── :safe → continúa al pipeline clínico normal (issue 003)
  │     └── {:crisis, level, triggers}
  │           ├── 1. Clinical.save_message(patient, texto, dek, "inbound", "spontaneous") — guardar cifrado
  │           ├── 2. Clinical.save_ai_diagnosis(msg_id, %{ai_response: mensaje_soporte_predefinido, extracted_emotions: %{crisis: true, level: level, triggers: triggers}}) (que guarda en la tabla `ai_diagnoses` via `Alethea.AI.Diagnosis`)
  │           ├── 3. Accounts.update_patient(patient, %{urgent_intervention: true})
  │           ├── 4. Phoenix.PubSub.broadcast(Alethea.PubSub, "crisis:alerts", {:crisis_detected, patient.id, level, triggers})
  │           └── 5. WhatsApp.Client.send_message(phone, mensaje_soporte_predefinido) → :ok
```

## Tasks

### Módulo `CrisisMonitor` (función pura)
- [ ] Crear `lib/alethea/alerts/crisis_monitor.ex` (`Alethea.Alerts.CrisisMonitor`):
  - `detect(text)` → `:safe | {:crisis, level, triggers}`
  - Lee los patrones desde `Application.get_env(:alethea, :crisis_patterns, default_patterns())`
  - Evalúa los patrones en orden de severidad descendente (`:immediate` primero, luego `:high`, luego `:low`)
  - `triggers` es la lista de substrings/patrones que hicieron match
  - La función no tiene efectos secundarios (sin llamadas a DB, sin PubSub, sin Oban)

### Configuración de Patrones y Soporte (Runtime)
- [ ] Añadir a `config/runtime.exs`:
  ```elixir
  config :alethea, :crisis_patterns, %{
    immediate: [
      ~r/me voy a matar/i,
      ~r/voy a suicidarme/i,
      ~r/tengo (?:el|un) plan/i,
      ~r/ya (?:lo|la) decid[ií]/i
    ],
    high: [
      ~r/quiero morir/i,
      ~r/no quiero (?:vivir|seguir)/i,
      ~r/pienso en (?:el suicidio|hacerme da[ñn]o)/i,
      ~r/me quiero hacer da[ñn]o/i
    ],
    low: [
      ~r/a veces pienso que ser[ií]a mejor no estar/i,
      ~r/no tiene sentido (?:seguir|vivir)/i,
      ~r/est[oá]y harto de (?:todo|vivir)/i
    ]
  }
  ```
- [ ] Añadir el mensaje de soporte predefinido en `config/runtime.exs`:
  ```elixir
  config :alethea, :crisis_support_message,
    """
    Entiendo que estás pasando por algo muy difícil. Lo que sientes importa.
    Por favor, comunícate con tu terapeuta directamente o llama a una línea de crisis:
    🇨🇱 Salud Responde: 600 360 7777 (24/7)
    🇨🇱 ACHS: 600 222 4357
    Si estás en peligro inmediato, llama al 131 (SAMU).
    """
  ```

### Pipeline — Integración en el Worker
- [ ] Actualizar `AletheaJobs.ProcessMessageWorker` para insertar la detección de crisis:
  - En la rama `terms_accepted: true`, antes del paso de guardar el mensaje, llamar a `CrisisMonitor.detect(texto)` sobre el texto en claro (antes de cifrarlo)
  - Si `:safe`: continuar con el pipeline normal
  - Si `{:crisis, level, triggers}`: ejecutar el flujo del Cortocircuito (ver diagrama) y retornar `:ok` sin llamar a `PhiWorker`
- [ ] Añadir `Accounts.update_patient/2` al contexto `Alethea.Accounts` si no existe

### Tests
- [ ] Crear `test/alethea/alerts/crisis_monitor_test.exs`:
  - Test por nivel `:immediate`: texto con patrón de emergencia inminente → `{:crisis, :immediate, [trigger]}`
  - Test por nivel `:high`: texto con ideación activa → `{:crisis, :high, [trigger]}`
  - Test por nivel `:low`: texto con ideación pasiva → `{:crisis, :low, [trigger]}`
  - Test de múltiples triggers: texto con dos patrones del mismo nivel → ambos en la lista `triggers`
  - Test de falso negativo: texto de conversación cotidiana → `:safe`
  - Test de texto vacío: `""` → `:safe`
  - Test de texto con emociones intensas sin riesgo ("estoy muy triste") → `:safe`

## Archivos Involucrados

| Acción | Archivo |
|---|---|
| NEW | `lib/alethea/alerts/crisis_monitor.ex` |
| MODIFY | `lib/alethea_jobs/process_message_worker.ex` |
| MODIFY | `lib/alethea/accounts.ex` (añadir `update_patient/2` si no existe) |
| MODIFY | `config/runtime.exs` (patrones + mensaje de soporte) |
| NEW | `test/alethea/alerts/crisis_monitor_test.exs` |

## Notas

- **Orden de evaluación**: los patrones `:immediate` se evalúan primero. Si hay match, se retorna sin evaluar `:high` ni `:low`. Esto garantiza que nunca se degrada la severidad de una crisis.
- **Texto en claro vs. cifrado**: `CrisisMonitor.detect/1` recibe el texto **en claro** (antes del cifrado), igual que `Sanitizer.sanitize/1`. El pipeline primero detecta, luego cifra.
- **`urgent_intervention` y reseteo**: el campo `urgent_intervention: true` no se resetea automáticamente. El profesional lo desactiva manualmente desde el dashboard (issue 006) al atender la alerta.
- **Ausencia de dependencias**: `CrisisMonitor` no tiene `alias`, `import` ni llamadas a módulos externos — es una función pura sobre texto. Esto la hace trivialmente testeable y resistente a errores de runtime.
- **Privacidad de `triggers`**: los triggers guardados en `Diagnosis.extracted_emotions` son los patrones (regex como string), no el texto del paciente. El texto ya está guardado cifrado en `messages`.
- **Sin migración**: esta issue no requiere cambios de schema. El campo `urgent_intervention` ya existe (issue 001) y `Diagnosis` ya acepta `extracted_emotions` como JSONB libre.
