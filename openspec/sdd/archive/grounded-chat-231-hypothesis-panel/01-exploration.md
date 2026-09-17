# Exploration — grounded-chat-231-hypothesis-panel

**Source issue:** alethea-org/Alethea#231
**Artifact store:** hybrid (mirrado a Engram `sdd/grounded-chat-231-hypothesis-panel/explore`)
**Strict TDD:** activo — test runner `mix test`.

## Current State

Rama de trabajo `feat/grounded-chat-231-hypothesis-panel` (fast-forward a `main`, con `lib/alethea_web/live/grounded_chat/followup_state.ex` de #228 ya incluido).

Ya existe un draft verde construido en esta sesión, antes de arrancar el ciclo SDD formal:

- `lib/alethea_web/live/grounded_chat/hypothesis_panel.ex` — `AletheaWeb.GroundedChat.HypothesisPanel.hypothesis_panel/1`, componente función stateless, con struct anidado `Claim` (`id`, `statement`, `citations: [Citation.t()]`).
- `test/alethea_web/live/grounded_chat/hypothesis_panel_test.exs` — 4 tests, todos en verde.

El componente reutiliza `AletheaWeb.CoreComponents.citation_list/1` verbatim (`lib/alethea_web/components/core_components.ex:563-611`), tal como exige el moduledoc de `Alethea.ClinicalRecord.Rag.Citation` (#230): *"C3 (issue #231) imports the same component for the Hipótesis panel, no divergent rendering"*. Confirmado: `citation_list/1` no expone passthrough de `expanded` — toda cita renderiza colapsada por diseño (no es un bug, hay un test explícito de #230 que lo fija así).

`Alethea.ClinicalRecord.Rag.Citation` y `AletheaWeb.CoreComponents.citation/1`/`citation_list/1` (#230, PR #248) fueron cherry-pickeados a esta rama en esta misma sesión — no están en `main` todavía, solo en `feat/grounded-clinical-chat-hypotheses`. Al traerlos aparecieron y se corrigieron: una colisión de nombres real (`AletheaWeb.ClinicalReviewPrototypeLive` tenía un `citation/1` privado que colisionaba con el `citation/1` recién importado — renombrado a `citation_excerpt/1`) y dos bugs preexistentes en los tests de #230 (mutación del campo equivocado en `reject_unknown_refs/2`, regex de mensaje de error desalineado con el mensaje real). Corregidos solo en esta rama — no reportados aún upstream.

Confirmado que `AletheaWeb.ConsultationLive` (el consumidor real, #227) **no existe en ningún lado del árbol actual** — solo mergeado vía PR #247 a `feat/223-grounded-clinical-chat`, no a `main`. `Consultation.Answer.outcome` sigue siendo `:synthesis | :no_evidence | :stale | :provider_failure` — sin variante de hipótesis en ninguna rama revisada (`232a-live-core`, `234a-wiring`).

`mix test` completo: 1029 tests, 1 falla preexistente no relacionada (`Mix.Tasks.Alethea.Demo.ResetTest`, lock de Postgres en tarea de reseteo de datos demo).

## Affected Areas (blast radius)

| Path | Acción | Notas |
|---|---|---|
| `lib/alethea_web/live/grounded_chat/hypothesis_panel.ex` | Ya creado | Interfaz (`Claim.t()`, `interpretive?`) provisional hasta que #229 exista |
| `test/alethea_web/live/grounded_chat/hypothesis_panel_test.exs` | Ya creado | Falta caso con 2+ claims (orden/agrupación) |
| `lib/alethea/clinical_record/rag/citation.ex` | Cherry-pick de #230 | Solo lectura desde acá, dependencia upstream |
| `lib/alethea_web/components/core_components.ex` | Cherry-pick de #230 (`citation/1`, `citation_list/1`) | Solo lectura desde acá |
| `lib/alethea_web/live/clinical_review_prototype_live.ex` | Modificado | Rename mecánico `citation/1` → `citation_excerpt/1` para resolver colisión |
| `openspec/adr/010-chat-consulta-clinica-fundamentada.md` | Fuente de verdad | Exige la *sustancia* del disclaimer, no un copy literal |

## Unaffected / confirmed stays

- `AletheaWeb.ConsultationLive` (#227) — no existe en esta rama ni en `main`; el panel se construye y testea de forma independiente, sin esa carcasa.
- La política C1 (#229, decide `interpretive?`) — cero commits reales en su rama; el panel no la implementa, solo define la interfaz que espera recibir.
- El core del citation renderer (#230) — se usa tal cual, sin modificar su comportamiento público.

## Decisiones de implementación

### Por qué reusar `citation_list/1` en vez de markup propio

El moduledoc de `Alethea.ClinicalRecord.Rag.Citation` lo exige explícitamente ("no divergent rendering") y evita que Síntesis (#234) e Hipótesis (#231) diverjan visualmente para el mismo tipo de dato.

### Por qué `Claim.citations: [Citation.t()]` en vez de campos sueltos (quote/source_ref/origin)

Evita duplicar un tipo que ya existe y ya está probado (#230); mantiene una única fuente de verdad para qué es una cita válida server-derived.

## Riesgos identificados

1. **No hay consumidor real todavía.** #227 no está en `main`, #229 tiene cero implementación. `Claim.t()` e `interpretive?: boolean()` son una interfaz asumida por esta sesión, no un contrato negociado — debe confirmarse explícitamente en `sdd-propose`/`sdd-design`, no darse por cerrado acá.
2. Sin confirmar: ¿la política C1 (#229) devuelve un booleano plano + lista de claims, o un resultado con tags más rico que el caller deba pattern-matchear antes de llamar a este componente?
3. Sin confirmar si `interpretive?: true, claims: []` es un estado alcanzable real o puramente defensivo.
4. No existe ningún test end-to-end de LiveView que pruebe el componente montado en un flujo real (`mount`/`handle_event`) — solo `render_component/2` aislado con assigns armados a mano.
5. El criterio de aceptación "separación visible respecto de Síntesis" no puede probarse desde este componente en aislamiento — pertenece a quien componga ambos paneles, que según el moduledoc de Citation es **#235**, no #231.

## Recomendación

El draft ya construido cumple sólidamente los criterios 2–4 de #231 (disclaimer antes del contenido, citas vía renderer real, no-render si no es interpretativa) con evidencia de test directa. El criterio 1 (separación visible) queda fuera del alcance verificable de este componente aislado. Antes de dar el draft por listo para propuesta formal: agregar un test con 2+ claims. Llevar el riesgo de interfaz no confirmada (`Claim.t()`/`interpretive?`) explícitamente a `sdd-propose` como pregunta abierta, no resolverlo unilateralmente acá.

**Ready for spec/design:** sí, con el riesgo de interfaz de #229 llevado explícitamente como pregunta abierta.
