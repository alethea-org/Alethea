# Demo runbook — Alethea

> Decidido el 2026-08-12. Fecha del demo: **martes 18 de agosto de 2026**.
> Audiencia: profesor (entrega final).
> Issue: #163 · Spec: #159 · Mapa: #112

## Q1 — Paciente en vivo (celular real) vs grabación

**Decisión:** Live con celular real.

**Justificación:** la única forma de demostrar que el pipeline end-to-end
funciona (Telegram ↔ webhook ↔ AI ↔ dashboard) es con un bot real y un
dispositivo real. El tiempo que ahorramos con grabación lo perdemos en
credibilidad ante el profesor.

**Fallback si Telegram cae durante el demo:** apagar el bot real, abrir el
dashboard con `use_mock_data: true` (referencia ticket #160) y mostrar el
flow pre-cargado. No intentamos recovery en vivo — pasamos al mock mode
de inmediato para que el profesor vea el producto funcionando aunque el
canal real falle.

## Q2 — Staging deploy vs localhost:4000

**Decisión:** localhost:4000 con `:dev` + `use_mock_data: true` para la base;
bot real de Telegram vía cloudflared tunnel.

**Justificación:** staging no está listo (no hay infra de deploy verde) y
localhost elimina el riesgo de "el deploy está roto". El cloudflared tunnel
expone el webhook al bot sin necesidad de deploy público.

**Blockers si staging:** N/A — descartado por falta de infra de deploy.

**Pre-demo check:** `bash scripts/setup_telegram_demo.sh` corre el bootstrap
completo (referencia ticket #162 `docs/demo-tech-setup.md`).

## Q3 — Quién hace de profesional / quién hace de paciente

- **Profesional:** Ana López (miembro del equipo).
- **Paciente:** Carlos Méndez (colega externo).
- **Briefing del paciente (requerido):** abrir el deep link que el profesional
  le pasa, tipear `/start`, esperar el bind confirmation, escribir 2-3
  mensajes preparados para demostrar el loop. NO necesita conocer el código;
  actúa como usuario real.

## Run-of-show (orden de operaciones)

1. El profesional abre `/dashboard` en localhost:4000 — briefing editorial
   renderea con picker toggle, triage strip vacía, lista de pacientes mock.
2. Click en "Lucca" — briefing column muestra metric strip lleno (ansiedad
   62%, social 41%, crisis 1, sesiones 5), 3+ session snapshots en el
   timeline, trend bars y daily chart con datos (ticket #160).
3. Click en "Invitar" — modal abre con `https://t.me/<bot>?start=<token>` y
   el código de 6 dígitos.
4. El paciente (colega externo) escanea el deep link o tipea el código.
   Telegram abre el bot, el paciente escribe `/start`.
5. Sistema vincula al foundation patient; el dashboard muestra el badge
   de confirmación.
6. El paciente escribe 2-3 mensajes preparados; Alethea responde vía
   Phi-4-mini + RoBERTa.
7. Vuelta al dashboard: el profesional muestra emoción actualizada,
   nuevos emotion rows, y cierra con "esto es lo que el profesional ve
   entre sesiones".

## Si algo sale mal

- **Telegram no responde:** fallback al mock mode (`use_mock_data: true`).
- **cloudflared tunnel no expone:** re-correr `scripts/setup_telegram_demo.sh`.
- **Mock data no renderea:** `mix ecto.reset && mix run priv/repo/seed_dev_bot_config.exs`.
- **Bot no bindea al /start:** verificar `TELEGRAM_BOT_TOKEN` en `.env`;
  re-ejecutar `mix alethea.telegram.bootstrap --env dev`.

## Dependencias externas

- Ticket **#160** (mock data) — debe estar merged antes del lunes 17.
- Ticket **#162** (`docs/demo-tech-setup.md`) — debe estar merged para
  referenciar los pasos del cloudflared + bootstrap.

## Cómo reversar una decisión

Cualquiera de las 3 puede revertirse antes del lunes 17 (24h antes).
Después de eso, los fallbacks definidos arriba son la red de seguridad.