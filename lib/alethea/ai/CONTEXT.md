# IA Orchestration: `lib/alethea/ai/`

Este es el cerebro cognitivo de Alethea. Aquí es donde los modelos de lenguaje (LLMs) se encuentran con los datos clínicos bajo el marco de **LangChain**.

## Propósito
Orquestar la inferencia híbrida para proporcionar una conversación guiada, análisis de sentimiento y mapeo de conducta sin comprometer la privacidad.

## Componentes Clave
*   **`chains/`**: Definiciones de LangChain para flujos específicos (ej. extracción de grafos).
*   **`tools/`**: Herramientas que la IA puede usar (ej. buscar en la base de datos vectorial).
*   **`roberta_worker.ex`**: Worker local para sentimiento (Bumblebee). No requiere internet.
*   **`phi_worker.ex`**: Interfaz con Phi-4 para la conversación interactiva.

## Guía para Desarrolladores y Agentes
1.  **Privacidad:** Nunca envíes contenido en claro a `phi_worker.ex` sin pasar por el filtro de sanitización.
2.  **Asincronía:** El procesamiento de IA es pesado. Siempre debe ser disparado por un worker de Oban para no bloquear el proceso de recepción del mensaje.
3.  **Trazabilidad:** Asegúrate de que cada resultado de IA incluya el `message_id` original para permitir el "Source Anchoring" en el dashboard.
