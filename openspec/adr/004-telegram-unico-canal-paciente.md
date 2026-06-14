# ADR-004: Telegram es el único canal del paciente

**Status:** Aceptado
**Fecha:** 2026-06-11
**Contexto:** Decisión de Fase 0 / Módulo 3 del grill-me (y motivación original del proyecto)

## Contexto y problema

El proyecto original contemplaba WhatsApp Business API como canal del paciente. WhatsApp tiene costos significativos por mensaje (~$0.05-$0.15 según país y tipo) y se volvió inviable económicamente.

El paciente no tiene cuenta en la app web. Su única superficie de interacción con Alethea es el canal de mensajería. Esto define el sistema casi por completo.

## Decisión

**Telegram Bot es el único canal del paciente. No se contempla WhatsApp ni SMS, ni siquiera como post-MVP.**

### Implicancias de producto
- El paciente nunca toca la web. Todo el flow de journaling, feedback, triggers, crisis detection pasa por Telegram.
- El psicólogo nunca toca Telegram. Su superficie es 100% web.
- El admin nunca toca Telegram. Su superficie es 100% web.

### Implicancias técnicas
- Telegram no tiene "templates aprobados" como WhatsApp Business. La conversación es libre. Esto es bueno para journaling pero requiere moderación.
- La única "API" del sistema es la de Telegram Bot (webhook). El resto es LiveView puro, sin OpenApiSpex (decidido en Módulo 4).
- El sistema está diseñado para que el día que se sume otro canal (ej. WhatsApp vía Twilio), sea un adapter nuevo, no un refactor del dominio.

## Consecuencias

### Positivas
- Cero costo por mensaje. Crítico para escalar la cantidad de pacientes por profesional.
- Telegram tiene buena DX de Bot API, webhooks estables, soporte multimedia.
- La decisión "solo Telegram" simplifica el modelo de auth del paciente (código de 6 dígitos al `/start` del bot, ya previsto en el issue viejo archivado).

### Negativas
- Los pacientes que no usan Telegram quedan fuera. No es un problema para el MVP pero hay que tenerlo presente.
- Telegram es un proveedor externo — si cambia políticas, hay impacto.

### Lo que NO entra
- App móvil nativa para el paciente.
- Notificaciones push (Telegram mismo se encarga de notificar al paciente).
- Multi-canal (WhatsApp, SMS). Es single-channel por diseño.
