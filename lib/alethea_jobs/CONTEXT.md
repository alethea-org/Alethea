# Background Infrastructure: `lib/alethea_jobs/`

Alethea no responde de forma síncrona. Todo el procesamiento pesado ocurre aquí para garantizar una experiencia fluida en WhatsApp.

## Propósito
Gestionar las colas de procesamiento asíncrono y resiliente utilizando **Oban**.

## Workers Principales
*   **`PipelineWorker`**: Orquesta el flujo: Ingesta -> Cifrado -> Sentimiento -> RAG -> Respuesta.
*   **`CleanupWorker`**: Tareas de mantenimiento y purga de datos.

## Guía para Desarrolladores y Agentes
1.  **Idempotencia**: Los workers deben poder reintentarse sin enviar mensajes duplicados al paciente.
2.  **Prioridad**: Los mensajes de WhatsApp tienen prioridad alta; las tareas de RAG o limpieza, prioridad baja.
3.  **Monitoreo**: Asegúrate de loguear errores de inferencia de IA para que el equipo pueda ajustar los modelos.
