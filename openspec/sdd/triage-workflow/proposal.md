# Proposal — triage-workflow

**Source issue/PR:** alethea-org/Alethea#152
**Artifact store:** hybrid (mirrored to Engram `sdd/triage-workflow/proposal`)
**Strict TDD:** active — test runner `mix test`.
**Depends on exploration:** `openspec/sdd/triage-workflow/exploration.md`

## Intent

**Problem.** El equipo de 5 personas que desarrolla Alethea no tiene un protocolo formal para asignar issues. La asignación ocurre por chat, "de palabra". Esto genera tres problemas recurrentes:

1. **Cuello de botella** — cuando la persona que asigna de facto no está, nadie avanza.
2. **Robo de contexto** — alguien toma una issue, invierte horas, y un tercero se la reasigna.
3. **Sin trazabilidad** — para la entrega de la materia "Proyecto" no hay forma limpia de responder "¿quién hizo qué?".

**Why now.** El proyecto está activo y el equipo necesita coordinarse sin bloquearse mutuamente. El contexto clínico de Alethea hace que perder horas por una mala coordinación tenga costo real (sesiones clínicas sin features completadas a tiempo).

**Success looks like.**

1. Cualquier dev del equipo puede tomar una issue en menos de 30 segundos (un slash command).
2. Una vez tomada, la issue no se le puede sacar a otro — el contexto del dev que la tomó está protegido.
3. Cada semana, alguien distinto del equipo hace de Product Owner, decide prioridades, y maneja decisiones HITL. Esto se rota automáticamente.
4. El evaluador de la materia puede auditar "quién hizo qué y cuándo" con comandos `gh` simples en menos de 5 minutos.
5. El vocabulario de labels es consistente con el existente (`type:*`, `wayfinder:*`).

## Scope

### In scope

- **GitHub Actions workflows** (`.github/workflows/triage.yml`, `rotate.yml`, `setup-labels.yml`).
- **Issue templates** (`.github/ISSUE_TEMPLATE/{bug,feature,task}.yml`) con auto-label `status:needs-triage`.
- **PR template** (`.github/PULL_REQUEST_TEMPLATE.md`) con checklist de TDD + áreas sensibles.
- **CONTRIBUTING.md** con 3 secciones: La idea / Cómo / Reglas duras, más vocabulario de labels.
- **QUICKSTART.md** (~300 líneas) con overview, 3 escenarios (tomar+terminar, semana como PO, issue bloqueada), tabla para evaluador, anti-patrones.
- **README.md** con sección Onboarding arriba.
- **ROTA.yml** con el orden de rotación y PO actual.
- **Issue pinneada #150** "📋 Triage rota — Alethea" como fuente de verdad visible.
- **16 labels nuevos** creados vía `setup-labels.yml`.

### Out of scope (deuda explícita para PRs futuros)

- `CODEOWNERS` por área (capa extra de protección para PRs).
- Workflow de stale-issues / cierre automático.
- Métricas semanales automáticas (resumen de commits, líneas, etc).
- Notificaciones Slack/Discord cuando hay rotación.
- Auto-claim desde la UI (sólo vía slash command por ahora).

## Approach

### Approach 1 — Workflows + slash commands + label-driven state machine (SELECCIONADA)

Implementar todo el modelo en GitHub Actions. La máquina de estados de una issue vive en labels (`status:*`), los transiciones se disparan por eventos (`issues.opened`, `issue_comment.created`, `pull_request.closed`), y el enforcement vive en el workflow `triage.yml`.

**Por qué seleccionada**: GitHub Actions es la infra que ya usa el repo (CI de Elixir). No introduce dependencias externas. El modelo es puramente declarativo (YAML + un poco de JavaScript inline en `actions/github-script`).

**Componentes del modelo**:

```
Estado de una issue:
  status:needs-triage  ──/claim──►  status:claimed  ──PR merge──►  status:done
                                  │
                                  └──/blocked <razón>──► status:blocked
                                       │
                                       └──/unblocked──► status:claimed

Acceso a /claim:
  ✓ Miembro de la org (author_association in [MEMBER, OWNER])
  ✗ Cuenta externa o bot → rechazado con mensaje
  ✗ Issue con wayfinder:prototype o wayfinder:grilling → rechazado con mensaje

Modificaciones a assignees (hard lock):
  ✓ El assignee actual (puede reasignarse a sí mismo sin ruido)
  ✓ El PO de la semana (cualquier reasignación con justificación)
  ✗ Cualquier otro → revertido por el bot
```

### Approach 2 — Bot dedicado externo (REJECTED)

Crear una cuenta `alethea-triage-bot` que corra en algún servidor y maneje toda la lógica. Por qué no: introduce infraestructura externa, rotar PATs, manejar downtime. Para un equipo de 5 personas en un proyecto de materia es overkill.

## Affected areas

| Area | Path | Change |
|---|---|---|
| Workflows | `.github/workflows/triage.yml` | Nuevo — 7 jobs (auto-triage, /claim, /release, /blocked, /unblocked, hard-lock, cap-one, pr-done) |
| Workflows | `.github/workflows/rotate.yml` | Nuevo — cron lunes 10:00 ART, lee y actualiza ROTA.yml + issue #150 |
| Workflows | `.github/workflows/setup-labels.yml` | Nuevo — bootstrap idempotente de 16 labels |
| Templates | `.github/ISSUE_TEMPLATE/{bug,feature,task}.yml` | Nuevos |
| Docs | `.github/CONTRIBUTING.md` | Nuevo — 3 secciones + vocabulario |
| Docs | `.github/QUICKSTART.md` | Nuevo — ~300 líneas con Mermaid + tabla evaluador + anti-patrones |
| Docs | `.github/PULL_REQUEST_TEMPLATE.md` | Nuevo — checklist TDD |
| Config | `.github/ROTA.yml` | Nuevo — orden de rotación |
| Repo root | `README.md` | Modificado — agregar sección Onboarding |
| Repo remoto | Issue #150 | Creada — pinneada post-merge manual |

## Risks / open questions

- **Primera ejecución del rotate.yml sin current_po**: si alguien borra `current_po` de `ROTA.yml`, el workflow arranca desde `order[0]`. Aceptable: documented behavior.
- **Race condition en `/claim` simultáneo**: si dos devs comentan `/claim` en la misma issue en el mismo segundo, GitHub serializa los eventos pero el segundo recibe "Ya tomada por @X". Aceptable.
- **PR soft check no bloquea merges**: la idea es documentar, no autorizar. Si el equipo quiere bloquear, es un cambio futuro.
- **El PO no puede transferir el rol**: si el PO está ausente, la presión social lo busca. No hay automation de escape.
- **QUICKSTART y CONTRIBUTING se desactualizan juntos**: si cambia un comando, hay que actualizar ambos. Aceptable por ahora.

## Out of scope (summary)

CODEOWNERS, stale-issues, métricas, notificaciones, auto-claim UI, integración Slack/Discord.

## Next

Ready para `sdd-spec` y `sdd-design` (pueden correr en paralelo). No hay decisiones abiertas que bloqueen.
