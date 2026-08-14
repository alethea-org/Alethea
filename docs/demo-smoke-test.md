# Smoke test pre-demo — Alethea

> Issue: #161 · Spec padre: #159 (D2 — sistema editorial reemplaza el tema
> púrpura/índigo) · Referencia: #160 (mock data)
>
> Este documento es un checklist manual de ~5 minutos que se corre **antes
> de cualquier demo**, para confirmar que las tres superficies renderean
> correctamente. NO es el guion del demo — para eso, ver
> [`docs/demo-runbook.md`](./demo-runbook.md) (quién hace de qué, run-of-show
> completo, fallback en vivo). Este documento es el chequeo previo de "¿está
> todo prendido y se ve bien?" antes de arrancar ese guion.

## Setup previo (una sola vez)

- [ ] `MIX_ENV=dev` — el servidor corre en modo dev, no test/prod.
- [ ] `config/dev.exs` tiene `use_mock_data: true` en la línea
      `config :alethea, use_mock_data: false` (línea ~80). **Por defecto
      está en `false`** — si no lo cambiaste a mano, todas las superficies
      de paciente van a mostrar datos reales/vacíos en vez del mock
      pre-cargado. Cambialo, guardá, reiniciá `mix phx.server`.
- [ ] Corriste `mix run priv/repo/seeds.exs` (o `mix ecto.setup`, que lo
      incluye) contra la DB de dev — esto crea el profesional demo. La
      consola debe imprimir:
      ```
      Demo login seeded (dev, mock data):
        email:    demo.mock@alethea.invalid
        password: alethea-demo-mock-2026
      ```
      La password es `alethea-demo-mock-2026` salvo que hayas seteado
      `ALETHEA_SEED_PROFESSIONAL_PASSWORD` en el entorno — en ese caso usá
      ese valor.
- [ ] (Opcional, solo si querés ver el deep link completo en vez de sólo el
      código de 6 dígitos) `mix run --no-start priv/repo/seed_dev_bot_config.exs`
      — crea la fila `BotConfig` para `env=dev`. Sin esta fila, el modal de
      invitación muestra únicamente el código de 6 dígitos (el bloque del
      deep link no renderiza porque `@invite_modal.deep_link` es `nil`).
- [ ] Arrancá el server: `mix phx.server` → `http://localhost:4000`.

## Login

- [ ] Ir a `http://localhost:4000/login`.
- [ ] Completar `#login-email` con `demo.mock@alethea.invalid` y
      `#login-password` con la password de arriba. Enviar.
- [ ] Redirige a `/dashboard` autenticado.

## 1. `/` — Landing

URL: `http://localhost:4000/`

- [ ] Layout full-bleed — el hero ocupa todo el viewport, **sin** la caja
      centrada de `#auth-layout` (esa caja es para `/login` y `/register`;
      la landing usa el pipeline `:landing` con root layout `:landing`,
      sin `auth-layout`).
- [ ] Hero en dos columnas (`.ptla-hero`):
  - [ ] Columna izquierda: eyebrow "Diario clínico entre sesiones", h1
        "Llegá a la sesión sabiendo cómo estuvo la semana.", lede
        ("Tu paciente escribe por Telegram..."), dos CTAs
        ("Crear cuenta" / "Ya tengo cuenta"), línea de privacidad
        ("Cada paciente tiene su propia clave de cifrado...").
  - [ ] Columna derecha: mock decorativo del dashboard (`.ptla-shot`,
        `aria-hidden="true"`) — barra con 3 puntos, líneas y barras de
        gráfico simuladas. No es interactivo, no debe reaccionar a clicks.
- [ ] Banda 01/02/03 debajo del hero (`.ptla-band` / `.ptla-cols`):
      "01 Invitás al paciente", "02 Escribe durante la semana",
      "03 Leés el resumen" — tres columnas con `.ptla-num`.
- [ ] Footer con una sola línea: "Alethea — Centro de Control Clínico ·
      Cifrado por paciente".

**Si algo está mal:** si ves la caja de auth-layout boxeando el hero, el
`:landing` pipeline no está siendo usado — revisá que no haya un revert de
la ruta `GET /` en `router.ex` (debe usar `pipe_through([:landing])`, no
`:browser` ni `:browser_auth`). Si el mock decorativo no aparece, correr
`mix assets.build` (CSS/JS puede estar sin compilar tras un `git pull`).

## 2. `/dashboard` — Briefing editorial

URL: `http://localhost:4000/dashboard`

- [ ] Header: eyebrow "Centro de Control" + h1 con el nombre del
      profesional logueado ("Demo Professional (mock data)").
- [ ] **Triage strip vacía por defecto** — al cargar el dashboard sin
      ninguna alerta de crisis simulada, la franja roja de "Alertas
      críticas" (`.pta-triage`) **no debe aparecer** (el template la
      renderiza sólo `if @critical_patients != []`).
- [ ] **Triage strip con chips cuando hay un paciente crítico** — para
      verificar esto en el smoke test no hace falta esperar un evento real:
      basta con seleccionar (más abajo) al menos un paciente mock marcado
      como urgente en el picker semanal (`ptc-slot--risk`) o disparar una
      alerta simulada si tenés acceso a IEx (`send(pid, {:crisis_detected,
      %{patient_id: "p2", level: :high}})` en una sesión de desarrollo —
      ver `test/alethea_web/live/dashboard_live_test.exs` línea 40). Cuando
      hay al menos un paciente crítico, debe aparecer `.pta-triage` con un
      chip `.pta-chip.pta-chip--risk` por paciente, mostrando sus iniciales
      y alias.
- [ ] Picker toggle (`.ptd-toggle`, `role="group"`) con dos botones:
      "Pacientes" y "Semana". El activo tiene la clase
      `.ptd-toggle__btn--on` (fondo oscuro, texto claro).
  - [ ] "Pacientes" muestra el buscador + chips de pacientes
        (`.pta-picker`, componente `PatientSearch`).
  - [ ] "Semana" muestra la agenda de 7 días (`.ptc-week` / `.ptc-day`),
        con el día de hoy resaltado (`.ptc-day--today`).
- [ ] Sin paciente seleccionado: tarjeta vacía con el texto "Elegí un
      paciente arriba para leer su briefing de la semana." (o el
      equivalente de semana).
- [ ] Configuración colapsada al fondo — bloque `<details class="pta-settings">`
      con `<summary>Configuración de tu bot (aplica a todos tus
      pacientes)</summary>`, cerrado por defecto, fuera de la columna de
      briefing (no compite visualmente con el contenido del paciente).

**Si algo está mal:** si "Centro de Control" no aparece o tira error 500,
revisá que `use_mock_data: true` esté seteado (paso de Setup) y que el
seed haya corrido — sin profesional demo, el login falla antes de llegar
acá. Si el picker no cambia de vista al clickear, correr
`mix assets.build` (JS de LiveView puede estar stale) y reiniciar el
server.

## 3. `/dashboard/patients/:id` — Detalle de paciente

Desde `/dashboard`, click en un paciente del picker (mock: "Juan Perez" /
`p1`, o el que aparezca resaltado en rojo si estás verificando la triage
strip).

- [ ] URL cambia a `/dashboard/patients/<id>`.
- [ ] Click en el botón "Invitar" (`id="tg-btn-<patient_id>"`, ej.
      `#tg-btn-p1`) — abre el modal `#invite-modal`.
  - [ ] Si corriste `seed_dev_bot_config.exs`: el modal muestra el enlace
        de Telegram (`#invite-deep-link`, con `href` empezando en
        `https://t.me/alethea_dev_bot?start=...`).
  - [ ] Si NO corriste ese seed (BotConfig ausente para el env): el bloque
        del deep link no aparece, sólo el código de 6 dígitos
        (`#invite-six-digit`).
  - [ ] En cualquier caso: el código de 6 dígitos siempre visible
        (`#invite-six-digit`) y la hora de vencimiento
        (`#invite-expires-at`, formato `HH:MM`, "vence a los 10 minutos").
  - [ ] Cerrar con `#invite-close` (la ×) — el modal desaparece.
- [ ] Resumen semanal (`article#weekly-pre-session-report`) con:
  - [ ] Eyebrow "Resumen semanal" + fecha del período.
  - [ ] Texto del resumen (`.pta-briefing__text`).
  - [ ] Metric strip (`#weekly-metrics`) con las 4 tiles — **sin guiones**
        (los guiones `—` son el estado vacío, no deberían verse en el
        paciente mock):
    - [ ] `#weekly-metric-anxiety` — "Ansiedad", valor tipo `62%`.
    - [ ] `#weekly-metric-social` — "Social", valor tipo `41%`.
    - [ ] `#weekly-metric-crisis` — "Crisis", valor entero (ej. `1`).
    - [ ] `#weekly-metric-sessions` — "Sesiones", valor entero (ej. `5`).
- [ ] Tendencias Emocionales (`#emotion-trends`) — barras de progreso no
      vacías, una fila por emoción (`#emotion-row-<key>`) con porcentaje.
- [ ] Evolución Emocional (`#emotion-chart`) — el gráfico diario de 7 días
      renderiza con datos, no aparece en blanco/plano.
- [ ] Sesiones anteriores — al menos 3 entradas en la timeline
      (`.pta-timeline .pta-timeline__item`), cada una con fecha, pill de
      estado y texto de resumen.
- [ ] Click en "Descifrar chat" (`#decrypt-chat-button`) — el botón cambia
      a "Chat descifrado" y aparece `#chat-history-panel` con mensajes
      (mock: contenido incluye `CONTENIDO DESCIFRADO (MOCK)`).

**Si algo está mal:** si el modal de invitación no abre o tira error, en
mock mode no debería tocar la DB (revisar consola del server por
excepciones de `BotConfig`/`Foundation`). Si el metric strip muestra
guiones (`—`) en vez de valores para el paciente mock, el resumen semanal
mock no tiene los scores seteados — revisar el generador de mock data de
#160. Si la timeline tiene menos de 3 entradas o el gráfico está vacío,
mismo origen: datos mock incompletos, no es un bug de template.

## 4. Chequeo de paleta editorial (regresión D2)

El sistema anterior tenía un gradiente púrpura/índigo en el sidebar
(`#6366f1 → #8b5cf6` en el logo/avatar, activo de nav en índigo,
`#cbd5e1` en el título de sección) que fue reemplazado por el sistema
editorial (tokens en `priv/static/assets/css/editorial.css`, sección
"App shell — sidebar + topbar"). Confirmar que la regresión no volvió:

- [ ] **Logo/avatar del sidebar** (`.app-sidebar__logo`,
      `.app-sidebar__avatar`, `.app-topbar__avatar`) — fondo sólido
      oscuro/tinta (`--pt-accent: #181d26`), **NO** gradiente púrpura
      (`#6366f1` → `#8b5cf6`).
- [ ] **Link activo del sidebar** (`.app-sidebar__link--active`) — fondo
      gris claro (`--pt-surface-2: #f8fafc`) con texto tinta, **NO** fondo
      índigo.
- [ ] **Superficie de la tarjeta de briefing** en `/dashboard/patients/:id`
      (`article#weekly-pre-session-report`, clase `.pta-briefing`) — fondo
      blanco (`--pt-surface: #ffffff`) con borde izquierdo tinta de 3px.
      **Nota:** el token `--pt-cream: #f5e9d4` está definido en
      `:root` de `editorial.css` pero, al momento de escribir este
      checklist, no está aplicado como `background` en ninguna regla del
      CSS ni en el HEEx del dashboard — la superficie de la tarjeta de
      briefing es blanca, no crema. Si tu expectativa es ver crema ahí,
      es una discrepancia entre este documento y el código real: repórtala,
      no la asumas resuelta.

**Si algo está mal:** si ves el gradiente púrpura/índigo, `editorial.css`
no se está cargando después de `app.css`, o volvió un revert del bloque
"App shell" (líneas ~426-473 del archivo). Correr `mix assets.build` y
reiniciar. Si persiste, confirmar el orden de carga de stylesheets en el
layout raíz (`editorial.css` debe ir después de `app.css` para ganar por
especificidad, según el comentario en el propio archivo CSS).

## Referencias

- Guion completo del demo: [`docs/demo-runbook.md`](./demo-runbook.md).
- Mock data (#160): `priv/repo/seeds.exs`, `priv/repo/seed_dev_bot_config.exs`.
- Contrato DOM bajo test: `test/alethea_web/live/dashboard_live_test.exs`.
- Sistema editorial: `priv/static/assets/css/editorial.css`.
