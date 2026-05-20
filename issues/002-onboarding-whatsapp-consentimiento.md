# Issue 002: Onboarding de WhatsApp y Consentimiento

**Type**: AFK
**Blocked by**: issues/001-registro-pacientes-boveda-segura.md
**User Stories Covered**: 4

## Description
Manejar el primer contacto del paciente a través de WhatsApp. El sistema debe interceptar el primer mensaje y no procesar ninguna información clínica hasta que el paciente acepte formalmente los términos legales.

## Tasks
- [ ] Añadir el campo `terms_accepted` (boolean, default false) a la tabla y esquema de `Patient`.
- [ ] Modificar `AletheaJobs.ProcessMessageWorker` para:
    - Identificar si el paciente tiene `terms_accepted: false`.
    - En caso negativo, enviar un mensaje interactivo de WhatsApp con los términos de privacidad y límites de la IA.
- [ ] Implementar un manejador en el webhook para procesar la respuesta de "Acepto".
- [ ] Asegurar que el sistema no guarde ningún mensaje clínico previo a la aceptación de términos.
