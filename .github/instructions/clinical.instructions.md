---
applyTo: "lib/alethea/clinical/**"
---

# Instrucciones: Módulo Clinical (Sesiones, Inferencia, pgvector)

Estas instrucciones aplican a todos los archivos dentro de `lib/alethea/clinical/`.

## Reglas de Sesión

- El `SessionManager` gestiona el estado de sesión diaria via Oban (`scheduled_at`).
- El timeout estándar es de **30 minutos** de inactividad por paciente.
- Al expirar: disparar análisis de sentimiento (RoBERTa local) + embeddings + Snapshot.
- El mensaje de despedida al paciente es OBLIGATORIO al cerrar sesión.

## Embeddings y pgvector

- Los embeddings son PII sensible. **NUNCA** los envíes a APIs externas sin anonimización.
- Usa `pgvector` para almacenamiento y búsqueda semántica local.
- Las queries de similitud usan el operador `<=>` de pgvector via Ecto fragment.

```elixir
# Búsqueda semántica local (sin llamadas externas)
from(e in ClinicalEntry,
  where: e.patient_id == ^patient_id,
  order_by: fragment("embedding <=> ?", ^query_vector),
  limit: ^limit
)
```

## Snapshots Clínicos

- El Snapshot es un resumen de **4 líneas máximo** generado por LangChain/Phi-4.
- Se genera SOLO al cerrar una sesión (asíncrono via Oban, no en tiempo real).
- Incluye siempre `source_message_id` del mensaje que disparó el cierre.
- Se almacena en su propia tabla con referencia a la sesión.

## Source Anchoring (Trazabilidad)

- Todo resultado clínico (diagnóstico, embedding, snapshot) DEBE incluir un
  `source_message_id` o `session_id` que lo conecte con los datos originales.
- Nunca almacenes resultados de inferencia "huérfanos" sin referencia a su origen.

## Etiquetado de Conducta

```elixir
# SIEMPRE distinguir el origen del dato
:spontaneous   # El paciente inició el mensaje
:elicited      # La IA preguntó y el paciente respondió
```
