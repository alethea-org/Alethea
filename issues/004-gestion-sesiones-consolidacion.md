# Issue 004: Gestión de Sesiones y Consolidación (Heavy Processing)

**Type**: AFK
**Blocked by**: issues/003-integracion-meta-api-ia-reflexion.md
**User Stories Covered**: 6, 3

## Description
Gestionar el ciclo de vida de la interacción diaria. El sistema debe detectar la inactividad y disparar el procesamiento pesado de datos de forma asíncrona para que el dashboard del psicólogo sea instantáneo.

## Tasks
- [ ] Implementar `Alethea.Clinical.SessionManager` para manejar estados de sesión.
- [ ] Configurar un timeout de 30 minutos por paciente usando jobs de Oban (`scheduled_at`).
- [ ] Al cumplirse el timeout o cierre explícito:
    - Ejecutar análisis de sentimiento local (RoBERTa/Bumblebee) sobre todos los mensajes de la sesión.
    - Generar y guardar embeddings en la tabla con soporte `pgvector`.
    - Generar el **Snapshot** clínico (resumen de 4 líneas) con LangChain y guardarlo en la DB.
- [ ] Enviar mensaje automático de despedida al paciente.
