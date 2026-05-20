# Issue 003: Integración con Meta API e IA de Reflexión

**Type**: HITL (Requiere tokens de Meta WhatsApp API)
**Blocked by**: issues/002-onboarding-whatsapp-consentimiento.md
**User Stories Covered**: 5

## Description
Establecer la comunicación real con WhatsApp y configurar el núcleo de la IA conversacional bajo las restricciones clínicas definidas.

## Tasks
- [ ] Implementar un cliente HTTP (ej: con `Req` o `HTTPoison`) para enviar mensajes a través de la Meta Graph API.
- [ ] Configurar variables de entorno (`WHATSAPP_API_TOKEN`, `WHATSAPP_PHONE_NUMBER_ID`).
- [ ] Diseñar el System Prompt para la IA (Phi-4 mini via LangChain) siguiendo los "No Negociables":
    - Prohibición de diagnóstico.
    - Cero consejos médicos directos.
    - Tono socrático y escucha activa.
- [ ] Integrar el flujo en el worker de Oban para responder al paciente de forma empática.
- [ ] Validar la firma `X-Hub-Signature-256` en el webhook de entrada para seguridad.
