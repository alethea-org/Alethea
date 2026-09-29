# Issue 360 — Weekly summary saves a JSON Schema and shows a false clinical alert

## Objective

When the weekly-summary LLM echoes the JSON Schema embedded in the system prompt (or otherwise returns a response with no valid clinical `summary_text`), `WeeklySummaryChain` must reject the response with an error instead of falling back to the raw model text. Today that fallback persists the schema itself as the clinical narrative and — because `infer_status_level/1` keyword-scans the raw text — can badge the patient with the highest-severity "Intervención Requerida" status taken from the schema's own `enum`, with zero clinical evidence.

Reference: https://github.com/alethea-org/Alethea/issues/360

## Root cause (verified on the branch point, `origin/main` @ ef6f8c4)

- `lib/alethea/ai/chains/weekly_summary_chain.ex` — `parse_structured_response/2`:
  - A schema echo IS valid JSON, so `StructuredOutput.parse_json_response/1` returns `{:ok, map}` with top-level `"type"/"properties"/"required"` keys.
  - `Map.get(map, "summary_text") || raw` then saves the raw schema string as `summary_text`.
  - `Map.get(map, "status_level") || infer_status_level(raw)` keyword-scans the raw echo; the enum contains "Intervención Requerida" and `"Intervención"` is checked first → false maximum-severity alert.
  - The `{:error, _}` branch (non-JSON narrative) has the same raw-fallback problem.
- `lib/alethea_jobs/weekly_report_worker.ex` persists whatever the chain returns; `Clinical.Summary.changeset/2` has no `status_level` inclusion validation; the Dashboard renders `summary_text` verbatim and `status_tone/1` maps "Intervención Requerida" to `"critical"`.
- `Alethea.AI.StructuredOutput.unwrap_schema_echo/1` exists (opt-in, from #316) but `WeeklySummaryChain` never opted in.

## Design decisions

1. **Reject at the chain boundary.** `WeeklySummaryChain` gains a public, pure `parse/2` (mirroring `FunctionalAnalysisDraftChain.parse/1`'s convention from #316): fence-stripped decode → opt-in `unwrap_schema_echo/1` → strict field validation. No valid clinical response → `{:error, reason}`, and `do_run/3` threads it through unchanged telemetry shape.
2. **Strict acceptance:** after unwrap, `summary_text` must be a binary that trims to non-empty, and `status_level` must be exactly one of `"Estable"`, `"Alerta"`, `"Intervención Requerida"`. Metric fields (`anxiety_score`, `social_score`, `emotional_range`, `crisis_events`) keep today's lenient parsing; `session_count` keeps the local-count fallback (arithmetic, not model output).
3. **Error reasons:** `:schema_echo` when the decoded map carries a top-level `"properties"` map (or the full prompt-schema shape: `"type" => "object"` + `"required"` list) and does not unwrap into valid clinical data; `:unparseable` for everything else that fails validation (bad JSON, plain narrative, blank `summary_text`, status outside the enum). A `properties`-wrapped payload whose values are REAL clinical data is accepted (consistent with #316 D1 semantics: unwrap-then-validate).
4. **`infer_status_level/1` is deleted.** Clinical status comes only from a valid model-declared enum value, never from keyword-scanning raw text (issue: "El estado clínico debe provenir únicamente de una respuesta clínica válida, nunca de las opciones enum del esquema").
5. **No source change in worker or Dashboard.** `WeeklyReportWorker` already returns `{:error, reason}` on chain failure (Oban retries, max 3), and `DashboardLive.handle_async/3` already flashes "No se pudo generar el resumen semanal." while leaving `@weekly_summary` untouched (last valid summary preserved). These paths only get regression tests.
6. **No `status_level` changeset inclusion validation.** `DashboardLive.status_tone/1` deliberately tolerates status strings from several sources (chain, session worker, seeds); tightening the shared changeset is out of scope for #360.
7. **`run!/1` stays as-is** (`{:ok, result} = run(params)`), matching every sibling chain; no caller uses it.

## Scope (allowed edit surfaces)

- `lib/alethea/ai/chains/weekly_summary_chain.ex` — modified.
- `test/alethea/ai/chains/weekly_summary_chain.ex` does not exist; new `test/alethea/ai/chains/weekly_summary_chain_test.exs`.
- `test/alethea_jobs/weekly_report_worker_test.exs` — add rejection regression (no row saved).
- `test/alethea_web/live/dashboard_live_test.exs` — add regression: chain error preserves last valid summary.

## Constraints and non-goals

- Non-goal: prompt/LLM provider changes; schema echo is a model-behavior fact to defend against.
- Non-goal: changes to `StructuredOutput` (its #316 contract is frozen for its callers).
- Non-goal: changeset-level status validation, Oban policy changes, Dashboard UI redesign.
- Comment language matches each file's existing convention (Spanish in `weekly_summary_chain.ex` and the worker test; English in the new chain test file and dashboard tests).

## Testing configuration

- TDD mode: strict (RED first with evidence, then GREEN).
- Focused command: `mix test test/alethea/ai/chains/weekly_summary_chain_test.exs test/alethea_jobs/weekly_report_worker_test.exs test/alethea_web/live/dashboard_live_test.exs`
- Final command: `mix precommit` (revert any unintended `mix.lock` churn outside the edit surface).

## Tasks

- [x] **ECHO-1 — RED: chain regression tests** (`test/alethea/ai/chains/weekly_summary_chain_test.exs`)
  - Status: completed. 17 tests; RED evidence: `mix test test/alethea/ai/chains/weekly_summary_chain_test.exs` → 0/17 passed (`parse/2 is undefined or private`).
  - Covers the issue's exact echo, real embedded schema echo, wrapper/double wrapper/full shape, no-derivation-from-echo, narrative/blank/missing/non-binary summary_text, missing/outside-enum status (incl. "Crítico", "estable", "", nil), full valid response, session_count fallbacks (omitted + garbled), fenced json, properties-wrapped real data accepted.

- [x] **ECHO-2 — GREEN: chain fix** (`lib/alethea/ai/chains/weekly_summary_chain.ex`)
  - Status: completed. Public pure `parse/2` (`decode → schema_echo? detection after failed build_report → opt-in unwrap_schema_echo → strict validation`), `@status_levels` exact enum, `infer_status_level/1` deleted (zero repo-wide references), `do_run/3` returns `{:error, reason}` with error meta in `[alethea, :ai, :chain, :stop]` telemetry, success keeps `tokens_used`. GREEN: 17 passed.

- [x] **ECHO-3 — Regressions: persistence + Dashboard flow**
  - Status: completed. Worker (`+33`): mocked `{:error, :schema_echo}` → `perform_job` errors and zero `type: "weekly"` rows. Dashboard (`+36`): pre-existing valid summary + mocked error → flash "No se pudo generar el resumen semanal.", previous narrative still rendered, no `properties` fragment, no `Intervención Requerida`, no `data-status-tone=critical`.

- [x] **ECHO-4 — Full validation + work-unit commit**
  - Focused: 63 passed, 1 skipped (pre-existing `@tag :skip`).
  - `mix precommit`: 1675 passed (6 doctests, 1669 tests), 5 skipped; `mix.lock` sha256 identical before/after; no churn outside surfaces.
  - Independent verification (gentle-ai-verify): PASS on all 6 checks (focused suites, precommit, no keyword scanning repo-wide, parse/2 contract, protected sources untouched, other callers — DemoProcessor/demo task/mocks — unaffected, telemetry shape, compile warnings-as-errors).
  - Commit: recorded below.

## Acceptance criteria (from the issue)

- [ ] A schema-echo response (or any response without a valid clinical `summary_text`) is rejected without saving any summary.
- [ ] The UI signals the failed generation and keeps the last valid summary.
- [ ] Clinical status comes only from a valid clinical response, never from the schema's enum options.
- [ ] Regressions exist for the chain, persistence, and the Dashboard flow.

## TDD and delivery evidence

- RED: `mix test test/alethea/ai/chains/weekly_summary_chain_test.exs` → 0/17 passed, all `UndefinedFunctionError` on `parse/2` (valid RED).
- GREEN: same command → 17 passed.
- TRIANGULATE: enum outsiders ("Crítico", "estable", "", nil), double wrapper, full-schema-shape without `properties`, fenced JSON, properties-wrapped real data accepted, `session_count` omitted + garbled fallbacks; worker proves zero persistence; dashboard proves preserved narrative + no DOM leakage.
- Focused suites: 63 passed, 1 skipped. Full `mix precommit`: 1675 passed, 5 skipped, no `mix.lock` churn.
- Independent verification agent: all checks PASS (contract, scope isolation, callers, telemetry, compile).
- Excluded from the commit: untracked `package.json`/`package-lock.json` (agent-skill tooling artifact, unrelated to #360).

## Commits

- Single work-unit commit on `fix/360-weekly-summary-schema-echo`: `fix(ai): reject weekly summary schema echo (#360)` (chain + 3 test files + this doc; hash in `git log`).
