# Demo Smoke Test

Use this fallback checklist after the canonical [demo operator guide](main-demo-operator-guide.md) has started the local synthetic demo and you are signed in. It verifies the visible demo surfaces only; it does not require ngrok, Telegram, Ollama, the emotion sidecar, or a webhook.

Use synthetic data only. Do not copy, display, record, or share patient details, chat content, invite links, six-digit codes, credentials, or identifiers.

## 1. Landing page

1. Sign out, then open `http://127.0.0.1:4000/`.
2. **Pass:** the landing page uses the full-bleed editorial layout rather than the centred authentication frame. It shows the Alethea header, `Iniciar sesión`, `Crear cuenta`, the headline `Llegá a la sesión sabiendo cómo estuvo la semana.`, and the three-step `01`/`02`/`03` band.
3. **Fail:** the landing content is constrained to an authentication card, missing its header or three-step band, or shows an error page.
4. Recover by returning to `http://127.0.0.1:4000/login`, signing in with the synthetic professional, and continuing. Do not create a real account.

## 2. Dashboard overview

1. Open `http://127.0.0.1:4000/dashboard`.
2. **Pass:** `Centro de Control` appears above the professional name, with the `Pacientes` and `Semana` picker toggle. Select each toggle and confirm the URL changes respectively to `/dashboard?picker=chips` and `/dashboard?picker=week`.
3. **Pass:** the chips view exposes the patient picker; the week view shows the `Lun` through `Dom` agenda. Select a synthetic patient from either view and confirm the page moves to `/dashboard/patients/:id`.
4. **Pass:** when a synthetic patient is selected, the briefing column includes `Briefing ·`, `Resumen semanal`, `Tendencias Emocionales`, and `Evolución Emocional`. The `Configuración de tu bot (aplica a todos tus pacientes)` section is collapsed until selected.
5. **Pass:** if the current synthetic data contains a critical patient, the `Alertas críticas` triage strip appears above the picker as a risk chip linked to that patient's detail. If no patient is critical, the strip is absent; that is expected and must not be treated as a failure.

## 3. Editorial palette

Inspect the dashboard before proceeding.

1. **Pass:** the sidebar logo and user avatar use a flat dark editorial surface, not a purple gradient.
2. **Pass:** the active sidebar link has a light neutral surface, not an indigo background.
3. **Pass:** the `Resumen semanal` briefing card has a cream surface.
4. **Fail:** any of these three checks shows the retired purple or indigo chrome, or a white/blue briefing card. Capture no patient data; report only the failed surface and URL.

## 4. Patient invite

1. On a selected synthetic patient's page, such as `http://127.0.0.1:4000/dashboard/patients/:id`, find the `Telegram` area. It should show `Sin conectar` and `Invitar` unless that patient is already connected.
2. Select `Invitar`.
3. **Pass:** an inline `Invitación para` panel appears with `Código de 6 dígitos`, an expiry time, `Regenerar`, and `Ocultar`. This is an inline accessible panel, not a modal dialog.
4. **Pass with BotConfig:** the panel also shows `Enlace de Telegram`. Confirm only that the link is present; do not open, copy, record, or expose it.
5. **Pass without BotConfig:** no Telegram link is shown, while the six-digit code remains visible. Do not record or share the code.
6. Select `Ocultar`. **Pass:** the panel closes and no outbound message is sent by this screen.

## Recovery

1. If a page fails to load or authentication expires, return to `http://127.0.0.1:4000/login`, sign in with the existing synthetic professional, and rerun only the affected check.
2. If the dashboard has no synthetic patient, use the canonical operator guide's synthetic bootstrap step. Do not add real data.
3. If a clean local demo is required, stop Phoenix first, then run `mix alethea.demo.reset --confirm`. This documented development-only reset removes local demo identities, clinical data, delivery records, and Oban jobs while preserving encrypted `BotConfig`, migrations, and Oban peer state. Bootstrap a fresh synthetic identity afterward.
4. If the invite panel lacks a link, treat the six-digit-code-only state as expected when no `BotConfig` is present. Do not configure credentials or change services for this visual smoke test.
