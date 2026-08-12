# Exploration — triage-workflow

**Source PR:** alethea-org/Alethea#152
**Artifact store:** hybrid (mirrored to Engram `sdd/triage-workflow/explore`)
**Strict TDD:** active — test runner `mix test`.

## Current State

El repo `alethea-org/Alethea` tiene:

- **6 colaboradores** (5 admins + 1 maintain): `@teofurlan`, `@eveernst`, `@huajar`, `@vicenzogiordana`, `@damianfrick01` (duplicado a remover), `@demianfrick` (oficial).
- **3 issues abiertas** con labels existentes: `wayfinder:map`, `wayfinder:task`, `ready-for-agent`.
- **16 labels pre-existentes**: defaults de GitHub (`bug`, `enhancement`, etc) + custom (`devops`, `testing`, `needs-human`, `ready-for-agent`, `type:chore`, `type:feature`, `type:refactor`, `wayfinder:grilling`, `wayfinder:map`, `wayfinder:prototype`, `wayfinder:task`).
- **3 issue types** configurados a nivel de org: Task, Bug, Feature.
- **NO hay issue templates**, NO hay PR template, NO hay `CONTRIBUTING.md`.
- **Workflows existentes**: solo `elixir.yml` (CI).
- **Settings del repo**: auto-assignment OFF, re-assignment ON (default).

## Slack / chat del equipo

No documentado en el repo. El equipo se coordina por el chat interno (no hay integración con el repo).

## Patrones existentes que respetar

### Labels con prefijos (`type:*`, `wayfinder:*`)

El equipo ya usa prefijos como namespaces. Los nuevos labels siguen el mismo patrón (`status:*`, `priority:*`, `area:*`, `triage:rotating`).

### Issue types (`Task`, `Bug`, `Feature`)

GitHub tiene los 3 issue types configurados. Los templates nuevos (bug.yml, feature.yml, task.yml) los aprovechan automáticamente.

### Sin CODEOWNERS, sin branch protection

El repo no tiene branch protection ni CODEOWNERS configurados. El equipo decide mergear por consenso. No introducimos CODEOWNERS en este cambio (out of scope).

## Blast radius del cambio

| Path | Acción | Notas |
|---|---|---|
| `.github/ISSUE_TEMPLATE/` | Crear | 3 archivos |
| `.github/PULL_REQUEST_TEMPLATE.md` | Crear | — |
| `.github/CONTRIBUTING.md` | Crear | — |
| `.github/QUICKSTART.md` | Crear | ~300 líneas |
| `.github/ROTA.yml` | Crear | — |
| `.github/workflows/triage.yml` | Crear | 7 jobs |
| `.github/workflows/rotate.yml` | Crear | 1 job con permisos especiales |
| `.github/workflows/setup-labels.yml` | Crear | 1 job manual |
| `README.md` (raíz) | Modificar | + sección Onboarding arriba |
| Repo remoto | Crear issue #150 | Pinneada post-merge |
| Repo remoto | Crear 16 labels | Via `setup-labels.yml` workflow |
| Repo settings | Modificar | Auto-assignment ON, re-assignment OFF |
| Org settings | Modificar | Remover `@damianfrick01` |

## Unaffected / confirmed stays

- **Code del proyecto Phoenix** (`lib/`, `test/`) — NO se toca. El triage es 100% del lado de GitHub, no de la app.
- **Workflow `elixir.yml`** — NO se toca. Sigue corriendo CI normalmente.
- **Labels existentes** — NO se renombran ni se borran. Solo se agregan nuevos.
- **`.github/agents/`, `.github/instructions/`, `.github/prompts/`, `.github/skills/`** — archivos para GitHub Copilot, no para el workflow de triage. NO se tocan.
- **`openspec/`** — directorio de decisiones de diseño existentes. NO se toca excepto agregar `009-triage-workflow.md` (ADR) y `sdd/triage-workflow/` (SDD).

## Decisiones de implementación

### Por qué `actions/github-script` en vez de runs de `bash` con `gh api`

- Menos código (no hay que manejar auth tokens).
- Tipado en JavaScript con acceso a `github.rest.*` autocomplete.
- Estándar de la comunidad para GitHub Actions custom.
- El equipo puede leer y mantener el código más fácilmente.

### Por qué `ROTA.yml` en vez de label en la issue pinneada

- Las labels no pueden contener usernames fácilmente (formato limitado).
- Un archivo YAML es más legible y editable.
- El workflow `rotate.yml` puede commitear cambios al archivo (un label requeriría otro approach).
- Documentado en `.github/ROTA.yml` mismo cómo editarlo.

### Por qué 7 jobs en `triage.yml` en vez de 1 con condicionales

- Logs separados en la tab Actions.
- Permisos diferentes por job (no necesario pero más limpio).
- Más fácil de testear cada job independientemente.
- Mejor para debugging cuando algo falla.

## Riesgos identificados

1. **El PAT del MCP no funciona con curl directo** (verificado durante implementación: 401). Por eso las labels se crean vía `github_issue_write` que sí funciona. El setup final via `setup-labels.yml` workflow es idempotente y maneja esto.
2. **`/claim` por bots**: cualquier GitHub App o bot con comment access puede intentar `/claim`. El check `author_association in [MEMBER, OWNER]` lo filtra.
3. **`pull_request.ready_for_review` se dispara múltiples veces**: si reabrís y cerrás un draft, el bot puede comentar 2 veces. Aceptable para v1.
4. **El hard lock puede irritar a admins**: si un admin intenta reasignar "porque sí", el bot revierte. El equipo debe entender que esto es intencional.
5. **`status:done` es un sello**: si una issue se reabre después de merge, el label sigue ahí. Documentado en CONTRIBUTING.

## Recomendación

**Approach 1 del proposal es el correcto**. Workflows + slash commands + label state machine, todo en GitHub Actions. Cero dependencias externas, consistente con el patrón del repo (CI ya en Actions).

**Ready for spec/design**: sí.
