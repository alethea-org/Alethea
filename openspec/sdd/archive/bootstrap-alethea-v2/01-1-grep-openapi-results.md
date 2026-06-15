# Audit: `open_api_spex` references before removal

Captured: 2026-06-11, branch `chore/remove-open-api-spex`.
Method: `grep -rn "open_api_spex\|OpenApiSpex\|SwaggerUIPlug\|AletheaWeb\.Schemas" lib/ config/ mix.exs mix.lock test/`.

## Scope correction (vs. proposal/design/tasks)

The proposal, design, and `03-tasks.md` task 1.3 all list **3 files** to delete. The actual code surface is **6 files** (3 file deletions + 1 dep edit + 1 controller deletion not listed + 1 router surgery):

| File | Action | Why |
|------|--------|-----|
| `mix.exs` (line 72) | edit | `{:open_api_spex, "~> 3.18"}` dep declaration. |
| `lib/alethea_web/api_spec.ex` | delete | Defines `AletheaWeb.ApiSpec`; `@behaviour OpenApiSpex.OpenApi`; 8 `OpenApiSpex.*` aliases. |
| `lib/alethea_web/api_spec/schemas.ex` | delete | Defines `AletheaWeb.Schemas`; 18 `OpenApiSpex.schema/1` macro calls. |
| `lib/alethea_web/controllers/open_api_spec_controller.ex` | delete | Calls `OpenApiSpex.resolve_schema_modules/1`. |
| `lib/alethea_web/controllers/swagger_ui_controller.ex` | **delete (not in proposal)** | Defines `AletheaWeb.SwaggerUIPlug`; embeds the swagger-ui CDN; no direct OpenApiSpex import, but its route is the `/api-docs` Swagger UI surface that becomes orphaned once the spec is gone. Keeping it would leave a dead route pointing at a non-existent `/openapi/` endpoint. |
| `lib/alethea_web/router.ex` | **edit (not in proposal)** | Remove `:swagger_ui` pipeline (lines 30-33), `/api-docs` scope (lines 57-61), and `/openapi` scope (lines 63-67). |
| `mix.lock` | edit (by `mix deps.unlock --unused`) | Remove `open_api_spex` and the `ymlr` transitive dep (OpenApiSpex 3.22.3 pulls it). |

## Test/codebase references checked

- `test/` — no references to `open_api_spex` / `OpenApiSpex` / `SwaggerUIPlug` / `AletheaWeb.Schemas` / `AletheaWeb.ApiSpec`. No test asserts the Swagger UI or `/openapi` route.
- `config/` — no references.
- `assets/` — no references.
- `priv/` — `priv/static/api-docs/` is mentioned only in `openspec/archive/issues-v1/PLAN-DE-ISSUES.md` (archived, untouched).
- `openspec/sdd/bootstrap-alethea-v2/` — many matches, all in **the spec/proposal/design/tasks docs themselves**. These are intentionally descriptive and stay.
- `openspec/adr/004-telegram-unico-canal-paciente.md` — historical mention; stays.
- `.pi/mem-summaries/bootstrap-alethea-v2.md` — Engram cache; out of scope.

## Baseline (pre-removal, branch tip = `origin/main`)

```
$ mix test
... (truncated, 9.1s) ...
224 tests, 1 failure, 5 skipped
```

The 1 pre-existing failure is in `test/alethea_jobs/session_reminder_worker_test.exs:46` (`SessionReminderWorker` raises `:network_timeout` on the WhatsApp send path). **Note:** the proposal/no-go docs claim the failure is at `page_controller_test.exs:6` ("Bienvenido a Alethea" copy mismatch). That claim is stale — the actual failing test moved/rotated. The contract is unchanged: 224 + 1 + 5 must be preserved, whatever the failure's exact location. The failure is unrelated to OpenApiSpex and out of scope per the no-go manifest.

## Risk surfaced

- **Scope drift risk**: the proposal/design undercounted the removal surface (3 files listed, 6 files actually touched). A review that only checks the 3 listed files would miss `swagger_ui_controller.ex` and the router scopes. This audit doc closes the gap; the implementer must apply all 6 file actions.
- **Lock-file breadth**: `mix deps.unlock --unused` will also drop `:ymlr` (transitive dep of OpenApiSpex 3.22.3). That is expected — `:ymlr` is unused once OpenApiSpex is gone. No action needed.

## Verification post-condition (target)

- `mix test` reports 224 + 1 + 5 (no new failures, no new tests).
- `grep -rn "open_api_spex\|OpenApiSpex" lib/ config/ mix.exs mix.lock` returns zero matches.
- `mix compile --warnings-as-errors` clean.
- `mix format --check-formatted` clean.
