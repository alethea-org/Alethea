# ADR-002: Embeddings del RAG en modelo multilingüe vía Hugging Face Inference

**Status:** Aceptado
**Fecha:** 2026-06-11
**Contexto:** Decisión de Fase 0 / Módulo 4 del grill-me

## Contexto y problema

El RAG del sistema es la **historia clínica navegable del paciente**: ingesta mensajes de Telegram, transcripciones de sesiones, notas clínicas, psicometría, configuración de triggers, perfil. El psicólogo le pregunta a Alethea cosas como "¿qué medicación toma Juan?" o "¿hubo crisis en las últimas dos semanas?" y la IA tiene que recuperar la fuente correcta.

El sistema opera **en español**. Esto pesa en la decisión de embeddings.

Opciones evaluadas:
- OpenAI `text-embedding-3-small` (estándar de la industria)
- Voyage AI (especializado en retrieval)
- Cohere (multilingüe fuerte)
- Hugging Face Inference API con modelo multilingüe (`intfloat/multilingual-e5-large` o `BAAI/bge-m3`)

## Decisión

**Usar Hugging Face Inference API con un modelo multilingüe open source** (e5-large o bge-m3), vía `Alethea.AI.Embeddings` adapter.

## Consecuencias

### Positivas
- Los modelos multilingües rinden mejor en retrieval sobre texto en español que embeddings genéricos entrenados con predominio de inglés. Empíricamente, en benchmarks multilingües (MTEB), e5-large y bge-m3 están en el top para español.
- Open source: si un cliente grande pide que los datos no salgan a una API, se puede mover el mismo modelo a self-hosted sin cambiar el adapter.
- Privacidad razonable: HF Inference no entrena con requests.
- Costo bajo: free tier en desarrollo, costo por token bajo en producción.

### Negativas
- DX ligeramente peor que OpenAI (menos documentación, menos ejemplos en Elixir).
- Hay que elegir entre e5-large y bge-m3 — ambos sirven, benchmarks cambian por trimestre. Decisión se confirma en `sdd-new` del slice de embeddings.

### Mitigación
- Adapter `Alethea.AI.Embeddings` con interfaz `embed(text) :: {:ok, [float]}`. Cambiar de proveedor o modelo es cambiar el adapter.
- Decisión final del modelo (e5 vs bge) se toma en la fase de implementación, no acá.
