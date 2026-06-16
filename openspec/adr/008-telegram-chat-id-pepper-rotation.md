# ADR-008: Rotación del pepper de `telegram_chat_id_hash` requiere re-onboarding explícito

**Status:** Aceptado
**Fecha:** 2026-06-16
**Contexto:** Decisión del cambio `telegram-paciente-foundation` (PR #1b), locked desde Q4-bonus del proposal handoff.

## Contexto y problema

El sistema guarda `telegram_chat_id_hash = HMAC-SHA256(chat_id, pepper)` en la columna
`foundation_patients.telegram_chat_id_hash`. El pepper vive en la variable de entorno
`TELEGRAM_CHAT_ID_PEPPER` y protege la base de datos: sin el pepper, un atacante que
obtenga un dump de la DB no puede correlacionar `telegram_chat_id_hash` con el `chat_id`
real de Telegram.

Si el pepper se filtra (env var commiteada por error, exfiltración del secret store,
acceso no autorizado al vault de secrets), la base de datos queda efectivamente
de-anonimizada para esa columna. Cualquier dump que contenga `telegram_chat_id_hash`
puede vincularse con la API pública de Telegram.

Necesitamos una política de rotación que:

1. Haga que el modo de falla de un pepper filtrado sea **recuperable**, no permanente.
2. Sea **auditable** (un evento en el timeline del operador).
3. No destruya datos clínicos silenciosamente.

El `Message.body` (cifrado con `Cloak.Ecto` y DEK por paciente) es independiente del
pepper del chat_id — la decisión del pepper NO debe afectar el contenido de los mensajes.

## Decisión

**Opción (a) — Rotación manual + re-onboarding explícito.**

1. El pepper vive en **un solo lugar**: la variable de entorno `TELEGRAM_CHAT_ID_PEPPER`.
   Nunca se persiste a la base de datos, nunca se loguea, nunca se incluye en ningún
   dump de configuración.
2. El pepper **no tiene byte de versión**. Hay exactamente un pepper activo a la vez.
3. La rotación es una **acción manual del operador**: deploy con un nuevo
   `TELEGRAM_CHAT_ID_PEPPER` y ejecución de un Mix task
   `mix alethea.telegram.rotate_pepper --reason="..."` que:
   a. Setea todas las filas de `foundation_patients.telegram_chat_id_hash` a `NULL`.
   b. Marca todos los `foundation_patient_auth_codes` con `kind: "deep_link"` como
      `used_at: NOW()` (los códigos viejos son inútiles con un pepper nuevo — pero
      igual deben quedar como `used_at` para que no se puedan re-usar accidentalmente
      durante la ventana de rotación).
   c. Loguea un `Logger.warning` con la razón provista por el operador.
   d. Emite un PubSub broadcast en `ops:alerts` con `{:pepper_rotated, rotated_at: NOW()}`.
4. **Cada paciente debe re-onboarding** en el próximo `/start`. El mensaje de bienvenida
   posterior a una rotación incluye el copy: "Por tu seguridad, volvé a vincular tu
   cuenta. Tocá el link que te mandó tu terapeuta."
5. El `Message.body` (cifrado con Cloak.Ecto) **no se ve afectado** — el DEK por
   paciente es independiente del pepper del chat_id.

## Consecuencias

### Positivas

- **El blast radius de un pepper filtrado es un re-onboarding único, no un breach.**
  Si el pepper viejo ya está en manos del atacante, el atacante no puede hacer nada
  útil: la próxima lectura de la columna será `NULL`, y el próximo write será con
  el pepper nuevo. No hay ventana de doble-pepper.
- **No hay pérdida de datos silenciosa.** El `Message.body` queda intacto. El clínico
  puede reconstruir la historia clínica; lo único que pierde es el binding de chat
  (recuperable con el re-onboarding).
- **La rotación es auditable**: un solo Mix task ejecutado con una razón logueada
  es un evento limpio en el timeline. El operador puede demostrar compliance ante
  una auditoría ("rotamos el pepper el 2026-07-15 porque [razón]").
- **Simplicidad operacional.** No hay estado de "rotación en progreso", no hay
  dual-key migration, no hay período de gracia. El sistema está siempre en un
  estado coherente: un pepper activo, una columna con bindings válidos.

### Negativas

- **Cada paciente activo debe re-tapear un deep link.** Esto es fricción durante la
  ventana de rotación (especialmente en una base grande). Para una clínica con
  N pacientes, la rotación dispara N mensajes de re-onboarding.
- **El Mix task es una carga operacional.** Es el precio de "sin pepper versionado,
  sin rotación silenciosa". En un sistema de producción con muchos tenants, este
  costo se vuelve real — pero es el costo de la honestidad.
- **Si la rotación se ejecuta por error, hay que re-onboarding manualmente a todos
  los pacientes.** El Mix task debe pedir confirmación interactiva (o un flag
  `--yes` para bypass en emergencias).

### Mitigación

- El Mix task debe ser **idempotente**: ejecutarlo dos veces con el mismo pepper
  no debe cambiar nada la segunda vez. La auditoría de "ya rotó" se hace mirando
  el último `Logger.warning` con `reason:`.
- El PubSub broadcast en `ops:alerts` puede ser consumido por un LiveView de admin
  (cambio futuro, fuera de scope) que muestre "Pepper rotado el {fecha} — {N}
  pacientes pendientes de re-onboarding".
- El mensaje de bienvenida post-rotación debe ser **localizado** ("Por tu seguridad,
  volvé a vincular tu cuenta") para que el paciente entienda que es un evento de
  seguridad, no un bug.

## Alternativas rechazadas

- **(b) Pepper versionado, dual-hash en lectura** — RECHAZADO. La complejidad
  (dos HMACs paralelos, migración dual-key, eventual cutover) no compra suficiente
  seguridad sobre la simplicidad de la rotación manual. No estamos a escala de
  WhatsApp; la fricción del re-onboarding es asumible.
- **(c) Rotación silenciosa (leer ambos peppers, escribir al nuevo)** — RECHAZADO.
  Una rotación silenciosa es el peor modo de falla: el operador no sabe que pasó, y
  un pepper filtrado sigue activo en paralelo con el nuevo. Esto es exactamente lo
  que la política explícita está diseñada para evitar.
- **(d) Re-cifrar `Message.body` en la rotación** — RECHAZADO. El DEK por paciente
  no tiene relación con el pepper del chat_id. Re-cifrar es una operación
  destructiva (toca todas las filas del journal) sin beneficio de seguridad. Es un
  no-op conceptual disfrazado de mitigación.

## Q4-bonus referenciada

Esta decisión cierra la pregunta abierta Q4 del proposal: "¿Cómo rotamos el pepper
sin perder el binding de los pacientes activos?". La respuesta es: aceptamos la
pérdida del binding (recuperable vía re-onboarding) y preservamos los datos
clínicos. Es el trade-off correcto porque el binding es derivable (el paciente
puede re-tapear el link), pero el contenido del journal no lo es.

## Próximos pasos

- El Mix task `mix alethea.telegram.rotate_pepper` se implementa en un cambio
  separado (`telegram-paciente-pepper-rotation-task`), fuera de scope de
  `telegram-paciente-foundation`.
- El LiveView de admin para mostrar el estado de re-onboarding también es un
  cambio separado, posterior a la estabilización del canal Telegram.
- El wording del mensaje de bienvenida post-rotación se decide en la fase de
  producto del cambio de task (`grill-me` específico sobre el copy).