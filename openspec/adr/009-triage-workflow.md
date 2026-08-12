# ADR-009: Triage workflow con self-claim + rotating PO + hard lock

**Status:** Propuesto (revisión de equipo pendiente vía PR #152)
**Fecha:** 2026-08-11
**Contexto:** Cambio `triage-workflow` para coordinar al equipo de 5 personas en el proyecto Alethea (materia "Proyecto" UPE).

## Contexto y problema

Somos un equipo chico (5 personas) sin un rol formal de líder técnico. La asignación de issues estaba implícita: el que abría la issue la comentaba en el chat, alguien la tomaba "de palabra", y se trabajaba hasta que se terminaba.

Esto generaba tres problemas concretos que se repitieron en los últimos meses:

1. **Asignación manual centralizada en chat**: cuando el "asignador de facto" estaba ocupado o de viaje, nadie avanzaba. El equipo quedaba bloqueado esperando una respuesta que podía tardar horas o días.
2. **Robo de contexto**: alguien arrancaba una issue, invertía 3-4 horas leyendo código y planeando, y un tercero se la reasignaba (a veces sin querer, a veces por confusión). El trabajo se perdía.
3. **Sin trazabilidad para la entrega**: para defender el proyecto ante la cátedra, no había forma limpia de responder "¿quién trabajó qué?" o "¿quién fue PO cuándo?". El historial vivía en chat.

Tampoco había un protocolo claro para quién decidía qué cuando había una ambigüedad de producto (ej. "¿esta feature es priority:p0 o priority:p1?").

## Decisión

**Implementar el modelo "rotating PO + self-claim con hard lock" automatizado con GitHub Actions**, compuesto por:

1. **Self-claim por slash command**: cualquier dev del equipo toma una issue comentando `/claim`. El bot lo asigna automáticamente.
2. **Hard lock sobre asignaciones**: una vez tomada, nadie puede desasignar a otro. El bot revierte el cambio con un comentario explicativo. Solo el assignee actual o el PO de semana pueden modificar `assignees`.
3. **Cap de 1 assignee por issue**: enforced por un job que normaliza cualquier intento de tener >1.
4. **PO rotativo semanal**: los lunes a las 10:00 ART, un workflow rota automáticamente al siguiente PO según `.github/ROTA.yml`. El PO es el único que puede reasignar manualmente con justificación.
5. **Vocabulary de labels consistente**: `status:*`, `priority:*`, `area:*` se suma al vocabulario existente (`type:*`, `wayfinder:*`).
6. **Issue templates + PR template + QUICKSTART**: para que el flujo sea enseñable y auditable.

## Alternativas consideradas

### A) Asignación manual centralizada (status quo)

El líder técnico o el que abrió la issue asigna manualmente. Por qué no: es el origen de los 3 problemas. Cuello de botella + robo de contexto + sin trazabilidad.

### B) Auto-assign por label/área

Cada label `area:*` mapea a un usuario fijo. Si el dev de `area:encryption` no está, nadie toma esa issue. Por qué no: no resuelve el problema de fondo (sigue dependiendo de una persona), y rompe el principio de que cualquier dev puede tocar cualquier área.

### C) Cuenta bot dedicada sin PO humano

Un bot recibe todas las issues, las etiqueta, las reparte, y maneja `/claim` y `/release` desde su propia identidad. Por qué no: en un trabajo de materia, el equipo necesita que **todos** demuestren poder priorizar y decidir producto. La automatización autoritaria saca agencia humana.

### D) Self-claim sin hard lock

Cualquiera puede reasignar a otro. Por qué no: vuelve al problema #2. El hard lock es la protección de contexto que el equipo necesita.

### E) Rotating PO + self-claim + hard lock (SELECCIONADA)

La combinación que adoptamos. Self-claim para que la asignación sea inmediata y no haya cuello de botella. Hard lock para proteger contexto. PO rotativo para que todos ejerzan el rol de decisión de producto.

## Consecuencias

### Positivas

- **Elimina el cuello de botella.** La asignación es inmediata — no hay que esperar a que alguien decida.
- **Protege el contexto.** Una vez que tomaste una issue, es tuya. Nadie te la pisa. Si tenés que liberarla, vos decidís.
- **Auditable para la entrega de "Proyecto".** El evaluador puede responder "¿quién trabajó qué?" con `gh issue list --state closed --json assignees`. Puede responder "¿quién fue PO cuándo?" leyendo la issue #150.
- **Reparte la responsabilidad de producto.** Cada semana, alguien del equipo decide prioridades, destraba, y maneja las `triage:rotating`. Todos pasan por el rol.
- **Consistente con el vocabulario existente.** Los prefijos `status:*`, `priority:*`, `area:*` siguen el patrón de `type:*` y `wayfinder:*` que el repo ya usa.
- **No depende de infraestructura externa.** GitHub Actions + el repo mismo. No hay servicio de terceros que mantener.

### Negativas

- **Requiere disciplina del PO.** El PO tiene que estar activo. No hay escape para vacaciones (decisión explícita del equipo).
- **Depende de GitHub Actions.** No portable a otros SCMs. Aceptable: el equipo ya trabaja en GitHub.
- **El hard lock puede ser ruidoso.** Si alguien con admin intenta reasignar "por la fuerza", el bot revierte y comenta. Hay una curva de aprendizaje para entender por qué pasa.
- **`/claim` abierto a miembros requiere `author_association` check.** Si alguien externo intenta `/claim`, el bot rechaza. Hay que documentar que el bot distingue miembros de externos.

### Neutrales

- **5 labels nuevos** (`status:*` excepto `needs-triage`, `priority:*`, `area:*`, `triage:rotating`). El equipo necesita conocerlos, pero siguen el patrón existente.
- **Un nuevo workflow (`.github/QUICKSTART.md`)** es el contrato de lectura del modelo. Si el equipo lo lee, todo lo demás es obvio.

## Decisiones derivadas (resueltas durante el diseño)

- **`/claim` restringido a `author_association in [MEMBER, OWNER]`**: bots o cuentas externas no pueden tomar issues.
- **`wayfinder:prototype` y `wayfinder:grilling` exentas de `/claim`**: son artefactos HITL, las maneja el PO directamente.
- **Status `done` es sello histórico**: nunca se quita. La issue queda cerrada y el label queda como marca de auditoría.
- **No hay métricas automáticas** (resumen semanal de commits, etc). Para la entrega de Proyecto se usa la info cruda de GitHub.
- **El PO no puede transferir el rol** (`/handoff` rechazado explícitamente). El equipo acordó que el PO siempre maneja el backlog, aunque sea presión social.

## Próximos pasos

- **PR #152** ya está abierto con la implementación completa. Pendiente de review por el equipo.
- **Issue #150** "📋 Triage rota" es la fuente de verdad del PO actual y el orden de rotación.
- **Acciones manuales post-merge**: pinear #150, remover `@damianfrick01` de la org, configurar Settings → Issues (auto-assignment ON, re-assignment OFF), correr `Setup labels` workflow.
- **Cambios futuros fuera de scope**: `CODEOWNERS` por área para proteger PRs, métricas semanales, stale-issues workflow.

## Documentación relacionada

- `openspec/sdd/triage-workflow/proposal.md` — el QUÉ y POR QUÉ detallado
- `openspec/sdd/triage-workflow/spec.md` — comportamiento exacto de cada job
- `openspec/sdd/triage-workflow/design.md` — decisiones de diseño de cada workflow
- `openspec/sdd/triage-workflow/tasks.md` — tareas atómicas con dependencias
- `.github/QUICKSTART.md` — onboarding para devs y evaluadores
- `.github/CONTRIBUTING.md` — reglas formales y vocabulario de labels
