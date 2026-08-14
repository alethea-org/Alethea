# Guía de contribución — Alethea

> Esta guía tiene **tres secciones**. Empezá por la primera. Si entendés la idea,
> las reglas te van a parecer obvias; si no, las reglas te van a parecer arbitrarias.

---

## 🧠 La idea (leé esto primero)

Somos un equipo chico (5 personas) trabajando en **Alethea** como proyecto de la
materia "Proyecto" en la UPE. Esto define cómo nos coordinamos: **todos tenemos
que poder participar, todos tenemos que poder tocar código, y nadie tiene que
quedar esperando a otro para hacer su parte**.

Por eso la asignación de issues no es "el líder te asigna lo que te toca".
Es **auto-organizada** con tres reglas simples:

1. **Nadie te tiene que decir qué hacer.** Si ves una issue que te interesa y
   podés resolver, la tomás. La IA y los compañeros sugieren; vos decidís.
2. **Una vez que tomás una issue, es tuya hasta que la termines o la liberes.**
   Nadie te la saca. Eso te protege de que alguien te pise el trabajo o te
   haga perder contexto.
3. **Cada semana alguien distinto hace de Product Owner.** Su trabajo no es
   "mandar", es **destrabar**: revisar las issues `triage:rotating`, decidir
   prioridades, y ser el punto de contacto si hay un bloqueo. El resto de la
   semana puede seguir `claim`-eando issues con libertad.

Este modelo se llama **"PO + self-claim con hard lock"**. La rotación de PO,
si existe, se gestiona a mano vía PR a `.github/ROTA.yml`.

### Por qué funciona para nosotros

- **Elimina el cuello de botella.** Si la asignación depende de UNA persona,
  cuando esa persona está ocupada, nadie avanza. Con self-claim, la asignación
  es inmediata y el PO se libera para pensar producto, no para repartir tareas.
- **Elimina el robo de contexto.** Si vos arrancás una issue y alguien te la
  reasigna a mitad de camino, perdiste el trabajo. El hard lock te protege
  y te obliga a pedirte explícitamente que la liberes.
- **Reparte la responsabilidad de producto.** En un trabajo de materia, todos
  necesitamos demostrar que podemos priorizar, decidir, y destrabar. La
  rotación semanal garantiza que todos pasen por ese rol.
- **Es auditable.** Para la entrega de "Proyecto", queda registro de quién
  trabajó qué y quién fue PO cuándo.

### Por qué NO es "totalmente libre"

- **Sin hard lock**, alguien podría desasignarte la issue a vos mismo para
  quedársela, y tendrías un conflicto que resolver por chat.
- **Sin PO rotativo**, las decisiones de producto quedarían implícitas en el
  código, sin ownership claro.
- **Sin un assignee por issue**, el trabajo se diluye: dos personas tocando
  lo mismo se chocan, una persona termina haciendo todo y la otra nada.

---

## 🛠️ Cómo funciona en la práctica

### Para tomar una issue (cualquier dev del equipo)

1. Buscá una issue con label `status:needs-triage` y sin asignar.
2. Comentá `/claim` en ella.
3. El bot te asigna automáticamente y le pone `status:claimed`. Listo, es tuya.

### Si no podés seguir con una issue

1. Comentá `/release` en ella (solo vos, el assignee actual, podés).
2. Vuelve a `status:needs-triage`. Otro dev la puede tomar.

### Si te equivocaste al tomar una o querés pasársela a otro

1. Reasignala manualmente desde la UI de GitHub (mientras seas el assignee).
2. Avisale al otro por el chat del equipo.
3. La Action te deja reasignar a vos mismo como excepción al hard lock.

### Si la issue está bloqueada por algo externo

1. Comentá `/blocked <razón>` en ella (solo vos, el assignee actual, podés).
   Ejemplo: `/blocked esperando input de @fulanita sobre KEK rotation`.
2. El bot agrega `status:blocked` y comenta confirmando con la razón.
3. Cuando se destrabe: `/unblocked` (vos otra vez). Vuelve a `status:claimed`.

### Si la issue necesita una decisión de producto

1. Agregale el label `triage:rotating`.
2. Esperá al PO de la semana (ver issue #0 Triage rota).

### El PO activo

1. El PO activo se define en `.github/ROTA.yml`. El equipo lo cambia con un PR
   cuando lo decide.
2. Tu trabajo como PO: revisar issues con `triage:rotating`, resolver
   ambigüedades de prioridad/área, y destrabar a quien te pida ayuda.
3. **NO tenés que asignar a nadie.** Si querés reorganizar el trabajo,
   reasigná vos mismo con justificación; los demás siguen con self-claim.
4. **Las issues `wayfinder:prototype` y `wayfinder:grilling` son tuyas.** Son
   artefactos HITL — no se pueden `/claim`. Las manejás vos directamente
   (resolver, reasignar con justificación, o cerrar).

### Cuando tu PR mergea y cierra una issue

1. Tu PR usa la plantilla `PULL_REQUEST_TEMPLATE.md` con el body `Closes #N`.
2. Al mergearla, el bot pasa la issue de `status:claimed` a `status:done`.
3. `status:done` es **sello histórico**: no se quita nunca. Si reabrís la
   issue después, queda como marca de auditoría.

---

## 📋 Reglas duras (las que el bot enforce)

1. Toda issue nueva arranca con `status:needs-triage`.
2. Para tomar una issue: `/claim`. El bot asigna al comentarista.
   - Solo funciona para miembros de la org (MEMBER u OWNER).
   - Issues con `wayfinder:prototype` o `wayfinder:grilling` están exentas —
     las maneja el PO directamente.
3. Para liberarla: `/release` (solo el assignee actual puede).
4. Para bloquearla: `/blocked <razón>` (solo el assignee actual).
5. Para desbloquearla: `/unblocked` (solo el assignee actual).
6. **Nadie puede desasignar a otro.** Hard lock enforced por Actions. Solo el
   assignee actual o el PO de semana pueden modificar `assignees`.
7. **Una issue = una persona.** Si en el workflow se escapan >1, el bot deja
   solo al primero.
8. El PO activo está en `.github/ROTA.yml`. Cambia solo vía PR al archivo.
9. Una PR mergeada que cierra una issue con `status:claimed` la pasa a
   `status:done` automáticamente. El label no se quita.

---

## 🏷️ Vocabulario de labels

### Status (`status:*`)
- `status:needs-triage` — sin asignar, esperando triage o `/claim`
- `status:claimed` — asignada via `/claim`, **lock activo**
- `status:blocked` — asignada pero bloqueada por algo externo (`/blocked <razón>`)
- `status:done` — cerrada via PR mergeada; **sello histórico, no se quita**

### Tipo (`type:*`)
- `type:feature` — funcionalidad nueva
- `type:refactor` — refactor sin cambio funcional
- `type:chore` — mantenimiento, deps, housekeeping
- `bug` — algo no funciona
- `enhancement` — mejora a algo existente

### Prioridad (`priority:*`)
- `priority:p0` — bloquea release
- `priority:p1` — sprint actual
- `priority:p2` — backlog

### Área (`area:*`)
- `area:clinical` — `lib/alethea/clinical/`
- `area:encryption` — `lib/alethea/encryption/`
- `area:ai` — `lib/alethea/ai/`
- `area:telegram` — gateway/bot
- `area:accounts` — `lib/alethea/accounts/`
- `area:dashboard` — LiveView dashboard
- `area:jobs` — Oban workers
- `area:devops` — CI/deploy

### Wayfinder (`wayfinder:*`)
- `wayfinder:map` — mapa compartido (artefacto canónico)
- `wayfinder:task` — trabajo manual que destraba una decisión
- `wayfinder:prototype` — artefacto rough para reaccionar (HITL)
- `wayfinder:grilling` — decisión via grilling (HITL)

### Otros
- `ready-for-agent` — lista para que un agente AFK implemente
- `needs-human` — requiere decisión humana (credenciales, arquitectura)
- `triage:rotating` — esperando decisión del PO de la semana

---

## 🚀 Quickstart para devs nuevos en el equipo

1. **Empezá por [`.github/QUICKSTART.md`](./QUICKSTART.md)** — tiene 3 escenarios
   paso-a-paso con diagramas, comandos `gh` y tabla para evaluadores.
2. Volvé a esta guía (CONTRIBUTING) para las reglas formales cuando ya
   entendés la idea.
3. **Abrí la issue #0 Triage rota** para ver quién es el PO actual y el orden de rotación.
4. **Buscá issues con `status:needs-triage`** y `good first issue` para arrancar.
5. **Comentá `/claim`** en la que te interese.
6. **Andá a `mix test` y leé `AGENTS.md`** para entender el flujo de TDD del proyecto.
