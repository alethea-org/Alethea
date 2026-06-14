# Issue 005: Monitor de Crisis y Cortocircuito

**Type**: AFK
**Blocked by**: 001
**User Stories Covered**: P4, PR4, S3

## 🤝 Contrato de Paralelización (Contract-Driven Development)

Esta issue de seguridad perimetral se desacopla por completo del pipeline de IA y Telegram, permitiendo su desarrollo de forma 100% paralela desde el inicio.

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

## Description

Implementar una capa de seguridad crítica que detecte riesgo clínico en el texto del paciente antes de cualquier procesamiento del LLM, y cortocircuite el pipeline respondiendo con un mensaje de soporte humano con latencia mínima.

## Decisiones de Diseño

| Decisión | Elección | Justificación |
|---|---|---|
| Punto de ejecución | Dentro del worker de procesamiento, antes de llamar al pipeline de IA | Separa la lógica clínica de la capa web; el controlador solo recibe y encola |
| Patrones de riesgo | Lista de regex por nivel en `config/runtime.exs`, leída con `Application.get_env/2` | Ajustable sin recompilación; evita hardcodear terminología clínica en el código |
| Niveles de crisis | 3 niveles: `:immediate` (emergencia inminente), `:high` (ideación activa/plan), `:low` (ideación pasiva) | Granularidad clínica; cada nivel tiene su propio conjunto de patrones |
| Respuesta al paciente | Un solo mensaje de soporte predefinido para todos los niveles | El nivel se usa solo para la alerta al profesional; el paciente siempre recibe el mismo mensaje de contención |
| Persistencia al detectar crisis | Guardar mensaje inbound cifrado en DB + `Diagnosis` con `ai_response: nil` y `extracted_emotions: %{crisis: true, level: level}` | Trazabilidad completa; el dashboard puede ver el disparador |
| Marcado del paciente | `Accounts.update_patient(patient, %{urgent_intervention: true})` | Sin migración nueva; solo actualizar el booleano existente |
| Notificación al profesional | `Phoenix.PubSub.broadcast(Alethea.PubSub, "crisis:alerts", {:crisis_detected, patient_id, level, triggers})` | PubSub ya está en el supervision tree; el dashboard se suscribe a este topic |
| Canal de notificación | Dashboard + email | Push requiere app móvil |
| Tests | Tests de regresión unitarios puros sobre `CrisisMonitor.detect/1` | La función es pura por diseño; los tests son la red de seguridad ante cambios accidentales en los patrones |

## Flujo del Cortocircuito

```
Worker de mensaje (recibe de Telegram)
  ├── [NUEVO] CrisisMonitor.detect(texto_entrante)
  │     ├── :safe → continúa al pipeline clínico normal (IA)
  │     └── {:crisis, level, triggers}
  │           ├── 1. Clinical.save_message(patient, texto, dek, "inbound", "spontaneous")
  │           ├── 2. Clinical.save_diagnosis(msg_id, %{ai_response: mensaje_soporte, extracted_emotions: %{crisis: true, level: level, triggers: triggers}})
  │           ├── 3. Accounts.update_patient(patient, %{urgent_intervention: true})
  │           ├── 4. Phoenix.PubSub.broadcast(Alethea.PubSub, "crisis:alerts", {:crisis_detected, patient.id, level, triggers})
  │           ├── 5. Telegram.Client.send_message(chat_id, mensaje_soporte_predefinido)
```

## Tasks

### Módulo `CrisisMonitor` (función pura)
- [ ] Crear `lib/alethea/alerts/crisis_monitor.ex`
- [ ] Implementar 40+ patrones de detección

### Configuración de Patrones y Soporte (Runtime)
- [ ] Añadir patrones de riesgo a `config/runtime.exs`
- [ ] Añadir mensaje de soporte predefinido en `config/runtime.exs`

### Pipeline — Integración en el Worker
- [ ] Integrar la detección de crisis en el worker de Telegram
- [ ] Implementar el flujo de cortocircuito (bypass) y notificación PubSub

### Notificaciones
- [ ] Broadcast PubSub para dashboard
- [ ] Configuración de email para alertas

### Tests
- [ ] Tests de regresión unitarios sobre `CrisisMonitor.detect/1`
- [ ] Tests de integración de bypass

## Archivos Involucrados

| Acción | Archivo |
|---|---|
| NEW | `lib/alethea/alerts/crisis_monitor.ex` |
| MODIFY | `config/runtime.exs` (patrones + mensaje de soporte) |
| MODIFY | Worker de mensajes de Telegram |

## Notas

- **Orden de evaluación**: los patrones `:immediate` se evalúan primero. Si hay match, se retorna sin evaluar `:high` ni `:low`. Esto garantiza que nunca se degrada la severidad de una crisis.
- **Texto en claro vs. cifrado**: `CrisisMonitor.detect/1` recibe el texto **en claro**. El pipeline primero detecta, luego procesa.
- **`urgent_intervention` y reseteo**: el campo `urgent_intervention: true` no se resetea automáticamente. El profesional lo desactiva manualmente desde el dashboard al atender la alerta.
- **Ausencia de dependencias**: `CrisisMonitor` no tiene `alias`, `import` ni llamadas a módulos externos — es una función pura sobre texto. Esto la hace trivialmente testeable y resistente a errores de runtime.
- **Privacidad de `triggers`**: los triggers guardados en `Diagnosis.extracted_emotions` son los patrones, no el texto del paciente. El texto ya está guardado cifrado.
- **Canal Telegram**: el worker ahora recibe de Telegram, no de WhatsApp. El flujo de cortocircuito envía por Telegram también.
