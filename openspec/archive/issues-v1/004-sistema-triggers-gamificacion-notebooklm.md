# Issue 004: Sistema de Triggers, Gamificación y Vista NotebookLM

**Type**: AFK
**Blocked by**: 001
**User Stories Covered**: PR7, PR8, PR9, PR10, P3, P6

## Description

Implementar tres features principales:

1. **Sistema de Triggers** para que el profesional configure interacciones automáticas
2. **Gamificación** para que el paciente se sienta motivado a registrar
3. **Vista NotebookLM** para que el profesional explore los datos del paciente con IA

## Sistema de Triggers

### Tipos de Triggers

| Tipo | Configuración | Ejemplo |
|------|---------------|---------|
| **Pasivo** | "Si paciente dice **[palabra/tema]** → responder con **[contenido]**" | "Si menciona 'trabajo' → recordarle la técnica de respiración" |
| **Activo** | "En **[fecha/hora]** → enviar **[mensaje]**" | "Mañana 10am → '¿Cómo te fue en el parcial?'" |
| **Recurrente** | "Cada **[intervalo]** → **[acción]**" | "Cada domingo 9am → '¿Cómo estuvo tu semana?'" |

### UI de Configuración

Tres vistas separadas en el dashboard:
- **Vista Triggers Pasivos**: lista de reglas if-then
- **Vista Triggers Activos**: lista de acciones programadas
- **Vista Triggers Recurrentes**: lista de acciones periódicas

### Templates Predefinidos

El profesional puede partir de templates:
- "Cuando menciona **[tema]** → recordar **[estrategia]**"
- "En **[fecha]** → enviar **[mensaje]**"
- "Cada **[día de la semana]** a **[hora]** → **[acción]**"

## Gamificación

### Elementos

| Elemento | Descripción |
|----------|-------------|
| **Racha (streak)** | Días consecutivos de registro. "7 días seguidos registrando. ¡Vas muy bien!" |
| **Reflejo de IA** | La IA menciona algo del registro anterior: "Hace 3 días mencionaste que dormiste mejor. ¿Cómo seguís?" |
| **Emojis de estado** | 5 emojis: 🟢🟡🟠🔴⚫ para registrar estado rápido |

### Implementación

- Campo `current_streak` y `last_registration_date` en paciente
- Actualizar streak cuando el paciente registra
- Resetear streak si pasan más de 24h sin registro

## Vista NotebookLM

### Descripción

El profesional puede chatear con todos los datos del paciente:

| Datos disponibles | Descripción |
|-------------------|-------------|
| **Mensajes** | Todos los mensajes del paciente |
| **Emociones** | Scores de RoBERTa agregados por día |
| **Resúmenes** | Resúmenes semanales generados por IA |
| **Notas** | Notas privadas del profesional |

### Comportamiento

- **Solo lectura + sugerencias** — la IA responde preguntas y puede sugerir:
  - "Detecté que menciona trabajo 8 veces. ¿Querés crear un trigger pasivo?"
  - "Este resumen sugiere ansiedad creciente. ¿Querés marcar al paciente como requiring atención?"
- **Persistencia** — el profesional puede guardar y nombrar conversaciones
- **No modifica datos** — solo consulta, no crea ni modifica nada del paciente

### Ejemplos de preguntas

> "¿Cómo evolucionó el estado emocional de este paciente en las últimas 3 semanas?"
> "¿Hay patrones en sus mensajes?"
> "¿Debería crear un trigger para este tema?"

## Decisiones de Diseño

| Decisión | Elección | Justificación |
|---|---|---|
| Storage de triggers | Tabla `triggers` con JSONB para condiciones | Flexible, permite condiciones complejas |
| Execution de triggers activos | `TriggerWorker` con `scheduled_at` | Reutiliza infraestructura Oban existente |
| Templates de triggers | Enum de templates + texto libre | Empezar simple, permitir edición |
| Streak persistence | Campo en `patients` | Simple, rápido de consultar |
| NotebookLM storage | Tabla `notebook_conversations` + `notebook_messages` | Persistencia + navegación |

## Schema Propuesto

### Triggers
```elixir
defmodule Alethea.Clinical.Trigger do
  schema "triggers" do
    field :type, :string  # "passive", "active", "recurrent"
    field :name, :string
    field :config, :map  # JSONB con condiciones y acciones
    field :is_active, :boolean, default: true
    belongs_to :patient, Alethea.Accounts.Patient
    belongs_to :professional, Alethea.Accounts.Professional
    timestamps()
  end
end
```

### Notebook Conversations
```elixir
defmodule Alethea.Clinical.NotebookConversation do
  schema "notebook_conversations" do
    field :name, :string  # "Análisis semana 12"
    field :patient_id, :binary_id
    belongs_to :professional, Alethea.Accounts.Professional
    has_many :messages, Alethea.Clinical.NotebookMessage
    timestamps()
  end
end

defmodule Alethea.Clinical.NotebookMessage do
  schema "notebook_messages" do
    field :role, :string  # "user", "assistant"
    field :content, :text
    belongs_to :conversation, Alethea.Clinical.NotebookConversation
    timestamps()
  end
end
```

## Tasks

### Sistema de Triggers
- [ ] Crear schema `Trigger`
- [ ] Crear migración
- [ ] Crear `Clinical.create_trigger/2`, `list_triggers/2`, `update_trigger/2`, `delete_trigger/2`
- [ ] Crear `TriggerWorker` para triggers activos
- [ ] Integrar en el flujo de mensajes para triggers pasivos
- [ ] UI: Vista de triggers pasivos
- [ ] UI: Vista de triggers activos
- [ ] UI: Vista de triggers recurrentes
- [ ] Templates predefinidos

### Gamificación
- [ ] Agregar campos `current_streak`, `longest_streak`, `last_registration_date` a Patient
- [ ] Lógica de actualización de streak
- [ ] Mensajes de la IA con reflejo y streak
- [ ] Selector de emojis de estado

### Vista NotebookLM
- [ ] Crear schemas `NotebookConversation`, `NotebookMessage`
- [ ] Crear migración
- [ ] Crear contexto para conversaciones
- [ ] Integrar con LLM (Phi-mini o externo)
- [ ] UI: Chat interface
- [ ] Funcionalidad de guardar/nombrar conversaciones
- [ ] Sugerencias automáticas de triggers

## Archivos Involucrados

| Acción | Archivo |
|---|---|
| NEW | `priv/repo/migrations/<ts>_add_triggers.exs` |
| NEW | `lib/alethea/clinical/trigger.ex` |
| NEW | `lib/alethea/clinical/notebook_conversation.ex` |
| NEW | `lib/alethea/clinical/notebook_message.ex` |
| MODIFY | `lib/alethea/accounts/patient.ex` |
| MODIFY | `lib/alethea/clinical.ex` |
| NEW | `lib/alethea_jobs/trigger_worker.ex` |
| NEW | `lib/alethea_web/live/trigger_live/` |
| NEW | `lib/alethea_web/live/notebook_live/` |

## Notas

- **Privacidad**: los triggers son por paciente, pero el profesional puede ver todos sus triggers
- **Rate limiting IA**: el bottleneck de Phi-mini y RoBERTa actúa como rate limiting natural
- **Templates**: empezar con 5-10 templates básicos, expandir post-MVP
