# Demo UI and evidence fixes

Objective: fix the six issues the user reported on the deployed synthetic demo (2026-10-27).
Branch: `feat/synthetic-demo-ai` (PR #433). Delivery: same PR. Tests: `mix test`; CSS is hand-written in `priv/static/assets/css/` (no build step).

## Specs

- S1: Consultation page: "el input del mensaje está muy abajo de la pantalla."
- S2: Weekly summary: "El paciente había hablado de un examen que le fue mal, y en el resumen no aparece nada. La idea es que también aparezca la información de cómo fue la semana del paciente, qué hechos se dieron."
- S3: Patient briefing: "Acá tienen que tener más espacio entre sí las cards".
- S4: Revisión clínica: "Hay cosas que están muy pegadas entre sí", plus "mala UI" for the bottom save, version note and register actions.
- S5: "Me apareció un borrador de análisis funcional como evidencia."
- S6: "los filtros en sugerencias no funcionan, si pongo telegram, me siguen apareciendo todos".

## Tasks

- T1 [S1,S3,S4] inline; pending. CSS and markup spacing fixes. Risk: none.
- T2 [S2] inline; pending. The weekly summary also receives the week's sanitized inbound patient messages, so it can describe events. Risk: item 3, a prompt contract the chain consumes.
- T3 [S5] inline; pending. Functional analysis drafts stop being indexed and retrieved as evidence, and the existing draft chunks are purged. Risk: item 1, deleting stored derived chunks.
- T4 [S6] inline; pending. Source filters also apply to the empty-query suggestions. Risk: none.

## Log

- L1 (2026-10-27): the user's report quoted in S1–S6, with screenshots.
- L2: Mapping.
  - Consultation composer: no bottom padding, flush against `calc(100dvh - 64px)`.
  - Briefing: `.pt-card` has no margin; timeline items lack the `.pta-timeline` wrapper.
  - Review: `.version-selector` and `.review-draft` have no CSS; `.functional-analysis-actions` is a sticky bordered box shared by both forms.
  - Weekly: input is only `type: "session"` summaries, written 30 minutes after the last message.
  - Drafts: indexed through `functional_analysis_draft_saved` (`indexer.ex:93`).
  - Filters: empty-query suggestions are loaded once in `mount` without `source_kind` (`review.ex:183-192`).
