# ADR-001: LLM de Alethea corre en Groq, no on-device

**Status:** Aceptado
**Fecha:** 2026-06-11
**Contexto:** Decisión de Fase 0 / Módulo 4 del grill-me

## Contexto y problema

El sistema necesita un LLM que:

1. Converse con el paciente en Telegram (Alethea), con tono configurable por paciente.
2. Genere resúmenes de brecha antes de cada sesión.
3. Corra psicometría batch sobre el historial del paciente.
4. Responda al psicólogo en la vista NotebookLM (consulta sobre la historia clínica del paciente).

El proyecto anterior corría Phi-mini on-device. Esto implicaba costo operativo de infra (GPU, RAM), complejidad de deployment, y latencia variable.

## Decisión

**Usar Phi-4-mini corriendo en Groq como LLM principal de Alethea y de psicometría batch.**

## Consecuencias

### Positivas
- Costo operativo casi cero en desarrollo (free tier de Groq). Costo marginal bajo en producción.
- Latencia baja (Groq es muy rápido incluso en modelos chicos).
- Sin infra de GPU que mantener.
- Swap a un modelo más grande (Claude Sonnet, GPT-4o) es de una sola integración si en algún caso se justifica (ej. detección de crisis con alta sensibilidad).

### Negativas
- Los datos del paciente viajan a Groq (OpenAI-compatible API). Aceptable para datos no directamente clínicos en el MVP, pero **los resúmenes de brecha y la psicometría son derivados de datos clínicos** → hay que evaluar contrato de privacidad de Groq antes de producción.
- Dependencia de proveedor externo. Si Groq cambia precios o discontinúa el modelo, hay que migrar.

### Mitigación
- Toda llamada a Groq se hace detrás de un módulo `Alethea.AI.LLM` con interfaz estable. Cambiar de proveedor es cambiar el adapter, no el código de dominio.
- El sistema está preparado para usar modelos distintos por caso de uso (ej. Phi-4-mini para conversación, Claude Sonnet para crisis detection) sin refactor mayor.
