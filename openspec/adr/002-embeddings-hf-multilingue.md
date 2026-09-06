# ADR-002: Embeddings del RAG en modelo multilingüe local (BGE-M3)

**Status:** Aceptado (revisado)
**Fecha:** 2026-06-11 — revisado 2026-09-02
**Contexto:** Decisión de Fase 0 / Módulo 4 del grill-me — revisada en #191 (Grilling: Reconcile RAG implementation strategy with #165) y ratificada como canon en #193

## Contexto y problema

El RAG del sistema es la **historia clínica navegable del paciente**: ingesta mensajes de Telegram, transcripciones de sesiones, notas clínicas, psicometría, configuración de triggers, perfil. El psicólogo le pregunta a Alethea cosas como "¿qué medicación toma Juan?" o "¿hubo crisis en las últimas dos semanas?" y la IA tiene que recuperar la fuente correcta.

El sistema opera **en español**. Esto pesa en la decisión de embeddings.

Opciones evaluadas:
- OpenAI `text-embedding-3-small` (estándar de la industria)
- Voyage AI (especializado en retrieval)
- Cohere (multilingüe fuerte)
- Hugging Face Inference API con modelo multilingüe (`intfloat/multilingual-e5-large` o `BAAI/bge-m3`)
- **BGE-M3 self-hosted (Ollama), sin llamada a API externa**

La decisión original (2026-06-11) optó por Hugging Face Inference API. Esa decisión quedó **revertida** en #191/#193: los embeddings son una representación numérica derivable del contenido clínico y caen bajo el mandato de seguridad del proyecto — *"pgvector embeddings are PII: Never send raw embeddings to external APIs"* (`CLAUDE.md`). Enviar texto clínico a una API externa para generarlos, aunque el proveedor no entrene con los requests, es una superficie de exposición que el proyecto decidió no aceptar.

## Decisión

**Usar BGE-M3 (`BAAI/bge-m3`) local, servido vía Ollama**, sin llamada a ninguna API de embeddings externa, vía `Alethea.AI.Embeddings` adapter. Es parte del stack RAG inicial fijado en #193: PostgreSQL + pgvector, BGE-M3 local, generación local vía Ollama, retrieval híbrido (denso + full-text de PostgreSQL).

## Consecuencias

### Positivas
- BGE-M3 rinde bien en benchmarks multilingües (MTEB) para español, igual que en la decisión original.
- **Cero exposición externa**: el texto clínico nunca sale del perímetro de la aplicación para generar el embedding, cumpliendo el mandato de seguridad del proyecto sin depender de garantías contractuales de un tercero.
- Sin costo por token ni dependencia de disponibilidad de una API externa.
- Open source: mismo modelo, sin cambio de adapter si más adelante se re-evalúa el runtime (Ollama vs otro server local).

### Negativas
- Requiere infraestructura de inferencia local (Ollama) corriendo junto a la aplicación — operacionalmente más pesado que llamar a una API.
- Sin fallback gestionado por un proveedor externo si el servicio local cae; la disponibilidad del RAG depende de la disponibilidad de ese runtime.

### Mitigación
- Adapter `Alethea.AI.Embeddings` con interfaz `embed(text) :: {:ok, [float]}` ya existe (`lib/alethea/ai/embeddings.ex`); implementar el adapter real contra Ollama sin cambiar el contrato.
- El RAG es una proyección no autoritativa (#196): si el runtime de embeddings falla, el ClinicalRecord (fuente de verdad) sigue disponible; solo se degrada la indexación/retrieval.
