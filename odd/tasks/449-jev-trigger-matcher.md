# Issue #449 — Real TriggerMatcher adapter (Jev)
Objective: implement `Alethea.AI.TriggerMatcher.Jev` backed by TypeSafe System One (`POST /v1/systemone`), wire global threshold/timeout and production runtime activation, and verify with a Spanish synthetic evaluation set on branch `feat/449-jev-trigger-matcher`.

## Specs

- **S1**: "Implement the `TriggerMatcher` adapter chosen in the evaluation spike (Laya as a local sidecar following the emotion sidecar pattern, or Jev with sanitized input), with the threshold decided there as global configuration, and enable it in production." / "One Noul question per trigger, all in a single request. A global threshold from configuration decides a match; if several pass, the highest probability fires. At most one trigger per reply."
  - Implement `Alethea.AI.TriggerMatcher.Jev` (`@behaviour Alethea.AI.TriggerMatcherBehaviour`) using `Req` against TypeSafe System One `POST /v1/systemone` (default base URL `https://api.typesafe.ai`, default model `"jev-latest"`, header `Authorization: Bearer <api_key>`, `retry: false`, `redirect: false`).
  - Request JSON body: `%{"model" => model, "state" => sanitized_text, "questions" => questions}` where `questions` has one entry per candidate keyed by `candidate.id`, each with `"type" => "noul"`, Spanish matching instructions/condition, and clear `"criteria" => %{"true" => ..., "false" => ...}`.
  - Response parsing: HTTP 200 with `%{"answers" => answers}` maps each candidate `id` with `%{"type" => "noul", "noul" => p}` (`is_number(p)` and `p >= 0.0 and p <= 1.0`) to `p * 1.0` in `{:ok, probabilities}`.
  - Production configuration in `config/runtime.exs`: when `TRIGGER_MATCHER_ENABLED` is `"true"`, set `config :alethea, :trigger_matcher, Alethea.AI.TriggerMatcher.Jev`, configure `:jev_trigger_matcher` (`api_key` from `TYPESAFE_API_KEY` or `JEV_API_KEY`, `base_url` from `TYPESAFE_BASE_URL` or `JEV_BASE_URL` defaulting to `"https://api.typesafe.ai"`, `model` from `TYPESAFE_MODEL` or `JEV_MODEL` defaulting to `"jev-latest"`), and allow optional `TRIGGER_MATCH_THRESHOLD` and `TRIGGER_MATCH_TIMEOUT_MS` env overrides while keeping `0.7` and `5_000` in `config/config.exs`.
- **S2**: "- The adapter passes the spike's evaluation set at the decided threshold." / "- Build a Spanish evaluation set of (patient message, trigger condition, expected match) cases, including near-misses and multi-trigger messages, using synthetic data only."
  - Commit a Spanish synthetic evaluation set fixture/module and tests verifying that `Alethea.AI.TriggerMatcher.Jev` and `Alethea.Triggers.ReactiveMatch` pass every case (single match, near-miss below threshold, multi-trigger highest probability wins, no match) at the global `0.7` threshold.
- **S3**: "- Timeouts and errors degrade to \"no match\"." / "If the matcher errors or times out, the reply is generated without a trigger. The matcher never blocks journaling."
  - When `candidates == []`, `Jev.match/2` returns `{:ok, %{}}` without making any HTTP request.
  - When API key is missing/blank, HTTP status is non-200 (400, 401, 422, 429, 500, 529), payload is malformed, or `Req` returns a transport/timeout error, `Jev.match/2` returns `{:error, reason}` without raising, and `ReactiveMatch.find/2` degrades to `:none`.
- **S4**: "- If hosted, only sanitized text leaves the system; never embeddings."
  - `Alethea.AI.TriggerMatcher.Jev` defensively applies `Alethea.AI.Sanitizer.sanitize/1` to both the patient message text (`state`) and every candidate's `condition` before constructing the outbound JSON body, and never includes embeddings or raw unsanitized PII in the outbound HTTP request.

## Tasks

- [x] T1 (S1, S2, S3, S4) — route: gentle-ai-worker — commit: 8701760 — Implement `Alethea.AI.TriggerMatcher.Jev`, runtime config, and Spanish evaluation set + tests

## Log

- **L1**: User request verbatim: `necesitamos tener la demo dentro de dos días, así que vamos por lo más fácil. Usemos JEV. Termino la issue [Spike]: Evaluate Laya vs Jev for Trigger reactivo matching in Spanish #437 diciendo que vamos a usar JEV.`
- **L2**: User selected `close_437_and_start_449` (`Cerrar #437 y arrancar #449 (adapter Jev)`). Closed #437 on GitHub with decision comment.
- **L3**: TypeSafe System One API contract verified from `https://docs.typesafe.ai/api.md`: `POST /v1/systemone`, `Authorization: Bearer <API_KEY>`, request `{model, state, questions: %{id => %{type: "noul", instructions: ..., criteria: ...}}}`, response 200 `{model, answers: %{id => %{type: "noul", noul: float}}, usage: ...}`. Isolated worktree created at `.git/odd-worktrees/449-jev-trigger-matcher` on branch `feat/449-jev-trigger-matcher` from `main` (`e1bf5f4`) because primary worktree has active session `01a1acb0` working on #450.
- **L4**: Worker `mw3vnvru-2-p4n9` implemented `Alethea.AI.TriggerMatcher.Jev`, `config/runtime.exs` wiring, `test/support/fixtures/trigger_matcher_eval_set.ex`, `test/alethea/ai/trigger_matcher/jev_test.exs`, and `test/alethea/triggers/reactive_test.exs`. Parent consolidated `config/runtime.exs` tests into `test/config/production_runtime_config_test.exs` (`@managed_env`). `.env.example` untouched due to `.env*` guard.
- **L5**: Verification: `mix precommit` exit 0 (`2779 passed (6 doctests, 2773 tests), 5 skipped`). Native `gentle_review` `assess` returned `risk: "medium"`, `reviewDue: false` (`reviewDueReason: "under_budget"`), `independentVerifier: false`. Single cohesive slice boundary recorded at commit `8701760` (code ~180 lines, tests/fixtures ~790 lines).
