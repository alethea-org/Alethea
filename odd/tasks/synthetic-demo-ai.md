# Synthetic demo AI
Enable the complete synthetic-data demo for two restricted professional accounts; branch: `feat/synthetic-demo-ai`; baseline: `72a2a2f8ad585cfe4177d6c96ad34ee5bc8ee7b1`.
Delivery: `ask-on-risk` (chain strategy pending before commits); runner: ExUnit/Mix with isolated local PostgreSQL, never the Neon production database.

## Specs
- S1: "podemos directamente usar la api key de mi claude que tengo 200 USD gratis en vez de usar phi-4-mini". Add explicit Anthropic text generation while retaining existing local/OpenAI behavior. Validate configuration, public chain results, failures and log hygiene without paid calls. Actual API credit/model validation is pending credentials and authorization.
- S2: "todas las pantallas tienen que funcionar, todos los servicios tienen que funcionar". The accepted implementation sequence covers text generation, BGE-M3 embeddings with existing 1024-dimensional vectors, the existing emotion sidecar, and the missing transcription adapter, then complete synthetic-data E2E verification. No disabled-service substitute counts as completion.
- S3: "a mí y al profe". Hosted demo admission is restricted to the user and professor, not public registration. Configure identities explicitly; do not infer them from infrastructure logins. Outside the opt-in demo profile, preserve existing behavior. Restricted access does not prove that entered data is synthetic.
- S4: "dale vamos con eso". Implement the accepted phased plan. New infrastructure costs, paid provider calls, credentials transfers and deployment remain separately authorized; do not silently provision resources or change the production data boundary.

## Tasks
- T1 [S1] inline; pending; safe Anthropic provider, configuration, attribution, tests and docs; Risk: items 2/3 (sensitive logs and shared LLM contract); commit: pending.
- T2 [S1,S3] inline; pending; restricted opt-in demo admission and routing across the seven text chains, tests and docs; Risk: items 2/3 (admission and hosted clinical policy); commit: pending.
- T3 [S2,S4] inline; pending; embeddings/emotion hosting readiness, measured sizing, budget and authorized service deployment; Risk: item 5; commit: pending; actual provisioning awaits cost consent.
- T4 [S2,S4] inline; pending; production transcription integration, tests and docs; provider decision pending; Risk: items 2/5; commit: pending.
- T5 [S2,S4] inline; pending; authorized full app deployment and synthetic-data E2E evidence for every service; blocked on service readiness and deployment/paid-call consent; commit: pending.

## Log
- L1 — Original request: "qué sería lo mejor para poner en producción para una demo con datos ficticios? porque el profe quiere que pongamos en producción la app, y estaba pensando que en fly.io podemos deployar la app y lo que necesitábamos de ollama, podemos directamente usar la api key de mi claude que tengo 200 USD gratis en vez de usar phi-4-mini"
- L2 — Scope correction: "todas las pantallas tienen que funcionar, todos los servicios tienen que funcionar".
- L3 — Plan authorization: "dale vamos con eso". Access decision: "a mí y al profe" (submitted twice; one decision).
- L4 — Existing setup: 58 Neon production migrations verified; `alethea-prod` exists with eight staged variables, zero Machines. Telegram getMe verified. No webhook registration, app deployment or paid inference performed. Preserve all ignored credential files; never print them.
- L5 — Exploration: installed LangChain 0.3.3 has an Anthropic adapter, but its unexpected-response/error logging can expose raw payloads. Seven chains share LLMConfig; three declare local-only clinical policy. Guided attribution hardcodes Phi. Admission must cover existing sessions and remember tokens, not just registration UI. No email verification exists.
- L6 — Route: inline for all currently planned dependent units; no parallel writer or context-backstop trigger. Two bounded read-only explorers supplied routing maps. Forecast: approximately 650–1,000 authored lines for T1/T2, more for later services; choose a chain strategy before the first work-unit commit. No automatic push/PR.
- L7 — Workspace: existing human edits `CLAUDE.md` and `docs/agents/`, and earlier setup changes `.gitignore`, `neon.ts`, `opencode.json`, must remain outside these work-unit commits. Docker is not running; local PostgreSQL accepts connections and pgvector is installed. Use a separate local test database/temporary server and retain scratch cleanup ownership in the parent.
