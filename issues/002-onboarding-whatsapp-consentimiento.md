# Issue 002: Onboarding de WhatsApp y Consentimiento

**Type**: AFK
**Blocked by**: issues/001-registro-pacientes-boveda-segura.md
**User Stories Covered**: 4

## Description
Manejar el primer contacto del paciente a través de WhatsApp. El sistema debe interceptar el primer mensaje y no procesar ninguna información clínica hasta que el paciente acepte formalmente los términos legales.

## Tasks
- [ ] Añadir el campo `terms_accepted` (boolean, default false) a la tabla y esquema de `Patient` mediante una migración.
- [ ] Implementar la lógica de lookup de paciente por `whatsapp_number_hash` desde el número recibido en el payload del webhook: calcular el HMAC del número entrante con la salt del profesional y consultar la DB. Sin este paso, ningún mensaje puede ser asociado a un paciente.
- [ ] Modificar `AletheaJobs.ProcessMessageWorker` para:
    - Identificar si el paciente tiene `terms_accepted: false`.
    - En caso negativo, enviar un mensaje interactivo de WhatsApp con los términos de privacidad y límites de la IA.
- [ ] Implementar un manejador en el webhook para procesar la respuesta de "Acepto" y actualizar `terms_accepted: true`.
- [ ] Asegurar que el sistema no guarde ningún mensaje clínico previo a la aceptación de términos.
