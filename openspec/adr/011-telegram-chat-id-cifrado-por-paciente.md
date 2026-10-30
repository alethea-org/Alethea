# ADR-011: Guardar el chat id de Telegram cifrado con la clave del paciente

**Status:** Aceptado (decisión arquitectónica; implementación pendiente)
**Fecha:** 2026-10-30
**Contexto:** Triggers de pacientes — [#435](https://github.com/alethea-org/Alethea/issues/435), tarea [#436](https://github.com/alethea-org/Alethea/issues/436).
**Reemplaza:** la decisión «enqueue only at interaction» del [diseño de recordatorios de sesión](../sdd/archive/telegram-session-reminders/03-design.md#adr--enqueue-at-interaction-vs-cronstored-chat_id-decided).

## Contexto y problema

El diseño de recordatorios de sesión eligió encolar durante una interacción entrante de Telegram: el sistema conserva un hash HMAC del `chat_id`, que permite identificar al paciente pero no recuperar la dirección para enviarle un mensaje. El identificador original se obtiene durante la interacción y se pasa a los jobs de envío. La limitación aceptada fue que un paciente que no escribe entre sesiones puede no recibir recordatorios.

Los triggers activos necesitan enviar mensajes en el horario configurado por el psicólogo, aunque el paciente no haya escrito recientemente. Depender de una nueva interacción impide cumplir ese requisito. Conservar una dirección recuperable amplía los datos sensibles persistidos; debe quedar bajo el mismo límite de borrado criptográfico que los demás datos cifrados del paciente.

## Decisión

1. **Persistir el `chat_id` de Telegram cifrado con la clave de datos del paciente (DEK).** No se guarda en texto plano en el registro del paciente ni se cifra únicamente con una clave global compartida.
2. **Permitir envíos programados sin una interacción reciente.** El proceso de entrega autorizado recupera y descifra el identificador para enviar el mensaje por el canal Telegram existente. El hash HMAC sigue siendo un identificador de búsqueda, no una dirección de envío ni una alternativa al cifrado.
3. **Incluir el identificador en el borrado criptográfico del paciente.** Al destruir la DEK y sus copias recuperables, el `chat_id` cifrado queda irrecuperable y ya no puede usarse para iniciar envíos programados. No debe existir una copia recuperable bajo otra clave que eluda ese borrado.
4. **Reemplazar la restricción arquitectónica de encolar solo al interactuar.** Se revierte el rechazo a persistir un `chat_id` recuperable del diseño anterior, no sus demás decisiones de entrega, deduplicación ni seguridad.

## Consecuencias

### Positivas

- Los triggers activos pueden alcanzar a pacientes que no escribieron recientemente, sin esperar un nuevo mensaje entrante.
- El identificador persistido queda protegido por cifrado por paciente y cubierto por su borrado criptográfico.
- La entrega puede reutilizar el canal Telegram existente; el hash no necesita volverse reversible.

### Costos y límites

- Se incorpora un dato sensible recuperable en reposo. La implementación debe limitar el descifrado al proceso autorizado de entrega y evitar exponer el identificador en logs, errores o telemetría.
- La implementación necesita persistencia cifrada y captura del identificador al vincular el chat. Los hashes existentes no permiten reconstruirlo para pacientes ya vinculados.
- Destruir la DEK no borra copias del `chat_id` en texto plano. El diseño anterior ya lo pasa en `oban_jobs.args`; la implementación debe impedir que jobs pendientes o copias persistentes eludan el borrado. Este ADR no afirma que esa superficie ya esté resuelta ni que permita retirar mensajes entregados a Telegram.
- Esta tarea solo registra la decisión: no agrega columnas, no migra datos, no cambia los recordatorios existentes ni implementa los triggers activos. Esos cambios y sus pruebas de cifrado, entrega y borrado corresponden a la implementación posterior.

## Alternativas descartadas

- **Mantener «enqueue only at interaction»:** no alcanza a pacientes sin interacción reciente y por eso no satisface los triggers activos.
- **Guardar el identificador en texto plano o solo con cifrado global:** deja una dirección recuperable fuera del límite de borrado criptográfico por paciente.
- **Usar únicamente el hash HMAC para enviar:** no es reversible y Telegram necesita el `chat_id` original.
