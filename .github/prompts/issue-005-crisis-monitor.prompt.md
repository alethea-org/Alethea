---
description: "Issue 005 — Monitor de Crisis con cortocircuito de latencia mínima y notificación PubSub"
---

# Issue 005: Monitor de Crisis y Cortocircuito

Implementa la capa de seguridad crítica que detecta riesgo ANTES del LLM y
responde en milisegundos con el protocolo de apoyo humano.

## Contexto

- **Bloqueado por**: Issue 003 (pipeline de mensajes activo)
- **User Story**: 7 (protocolo de ayuda inmediata ante ideas de autolesión)
- **Módulos clave**: `Alethea.Alerts.CrisisMonitor`, `Alethea.Jobs.CrisisNotificationWorker`

## Tareas a Implementar

### 1. `Alethea.Alerts.CrisisPatterns`

```elixir
defmodule Alethea.Alerts.CrisisPatterns do
  @patterns Application.compile_env(:alethea, [:crisis_monitor, :patterns], [
    ~r/autolesion/i,
    ~r/suicid/i,
    ~r/no quiero (seguir )?vivir/i,
    ~r/quitarme la vida/i,
    ~r/hacerme daño/i,
    ~r/no vale la pena (seguir|vivir)/i,
    ~r/quiero morir/i
  ])

  def matches?(text), do: Enum.any?(@patterns, &Regex.match?(&1, text))

  def matching_pattern(text) do
    Enum.find_value(@patterns, fn p ->
      if Regex.match?(p, text), do: Regex.source(p)
    end)
  end
end
```

### 2. `Alethea.Alerts.CrisisMonitor`

```elixir
defmodule Alethea.Alerts.CrisisMonitor do
  alias Alethea.Alerts.CrisisPatterns

  @protocol_message """
  Escucho que estás pasando por algo muy difícil. Tu seguridad es lo más importante.

  🆘 Si estás en crisis, por favor contacta ahora:
  • Línea de la Vida (España): 024
  • Crisis Text Line: Escribe "HOLA" al 741741

  Tu terapeuta ha sido notificado/a y se pondrá en contacto contigo pronto.
  """

  @spec check(String.t(), String.t()) :: :ok | {:crisis, String.t()}
  def check(content, patient_id) do
    if CrisisPatterns.matches?(content) do
      trigger = CrisisPatterns.matching_pattern(content)

      # Notificación asíncrona (no bloquea la respuesta de protocolo)
      %{"patient_id" => patient_id, "trigger" => trigger}
      |> Alethea.Jobs.CrisisNotificationWorker.new()
      |> Oban.insert()

      {:crisis, @protocol_message}
    else
      :ok
    end
  end
end
```

### 3. `CrisisNotificationWorker`

```elixir
defmodule Alethea.Jobs.CrisisNotificationWorker do
  use Oban.Worker, queue: :alerts, max_attempts: 5

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"patient_id" => patient_id, "trigger" => trigger}}) do
    # 1. Persistir la alerta en la BD
    Alethea.Accounts.mark_urgent_intervention!(patient_id, %{trigger: trigger})

    # 2. Notificar al dashboard del psicólogo en tiempo real
    Phoenix.PubSub.broadcast(
      Alethea.PubSub,
      "psychologist:alerts",
      {:crisis_detected, %{
        patient_id: patient_id,
        trigger: trigger,
        detected_at: DateTime.utc_now()
      }}
    )

    :ok
  end
end
```

### 4. Migración para `urgent_intervention`

```bash
mix ecto.gen.migration add_urgent_intervention_to_patients
```

```elixir
alter table(:patients) do
  add :urgent_intervention,        :boolean, default: false, null: false
  add :urgent_intervention_trigger, :string
  add :urgent_intervention_at,     :utc_datetime
end
```

### 5. Integración en el Pipeline

En `ProcessMessageWorker` o `AIProcessingWorker`, ANTES de llamar al LLM:

```elixir
case Alethea.Alerts.CrisisMonitor.check(raw_message, patient_id) do
  {:crisis, protocol_message} ->
    Alethea.WhatsApp.Client.send_text_message(patient_phone, protocol_message)
    :ok  # Cortocircuito: job completado, no continuar con LLM

  :ok ->
    # Continuar con el pipeline normal
    run_ai_pipeline(...)
end
```

## Tests de Regresión (CRÍTICOS)

Un test por cada patrón de crisis. **Estos tests NUNCA deben fallar:**

```elixir
@crisis_phrases [
  "quiero hacerme daño",
  "no quiero vivir",
  "quiero suicidarme",
  "voy a quitarme la vida",
  "quiero morir"
]

for phrase <- @crisis_phrases do
  test "detecta crisis: '#{phrase}'" do
    assert {:crisis, _msg} = CrisisMonitor.check(unquote(phrase), "patient-id")
  end
end
```

## Checklist

- [ ] `CrisisMonitor.check/2` ejecutado ANTES del LLM en el pipeline
- [ ] Respuesta de protocolo enviada en milisegundos (sin esperar IA)
- [ ] Patrones configurables en `config/config.exs`
- [ ] `urgent_intervention` y timestamp persisten en la BD
- [ ] PubSub notifica al dashboard del psicólogo con el trigger
- [ ] Test de regresión por cada patrón de crisis definido
- [ ] `mix precommit` pasa limpio
