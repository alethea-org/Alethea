# Issue 003: Integración con Meta API e IA de Reflexión

**Type**: HITL (Requiere tokens de Meta WhatsApp API)
**Blocked by**: issues/002-onboarding-whatsapp-consentimiento.md
**User Stories Covered**: 5

## Description
Establecer la comunicación real con WhatsApp y configurar el núcleo de la IA conversacional bajo las restricciones clínicas definidas.

## Tasks
- [ ] Crear migración para añadir el campo `behavior_type` (string: `"spontaneous" | "elicited"`) a la tabla `messages`. Este campo registra si el mensaje fue iniciado por el paciente (`spontaneous`) o fue una respuesta a una pregunta de la IA (`elicited`), cumpliendo el mandato de trazabilidad del GEMINI.md. Debe asignarse en el worker de Oban al guardar cada mensaje.
- [ ] Implementar un cliente HTTP usando `Req` (incluido con Phoenix, sin dependencia adicional) para enviar mensajes a través de la Meta Graph API.
- [ ] Configurar variables de entorno (`WHATSAPP_API_TOKEN`, `WHATSAPP_PHONE_NUMBER_ID`) en `config/runtime.exs`.
- [ ] Diseñar el System Prompt para la IA (Phi-4 mini via LangChain) siguiendo los "No Negociables":
    - Prohibición de diagnóstico.
    - Cero consejos médicos directos.
    - Tono socrático y escucha activa.
- [ ] Almacenar el System Prompt en `Application.get_env/2` (config), no hardcodeado en el módulo, para permitir ajustes sin recompilación.
- [ ] Implementar el manejo del historial de conversación para LangChain: al construir el prompt, leer y descifrar los últimos N mensajes del paciente desde la DB para proveer contexto clínico a la IA.
- [ ] Integrar el flujo en el worker de Oban para responder al paciente de forma empática.
- [ ] Validar la firma `X-Hub-Signature-256` en el webhook de entrada para seguridad (respuesta 403 inmediata si falla).
