# Review follow-ups: synthetic demo

Objective: resolve the 28 advisory findings from native review `review-3b8961b76aa0c2f0` of `feat/synthetic-demo-ai`.
Branch: `feat/synthetic-demo-ai`. Delivery: ask-on-risk. Test runner: `mix test` and `python -m unittest` (emotion sidecar).

## Specs

- S1: "arreglemos todo". Every advisory finding of review `review-3b8961b76aa0c2f0` gets fixed or is explicitly resolved in code, config, or docs. Finding IDs:
  - R1: public-ollama, public-emotion-sidecar, docs-contradict-exposure, unpinned-ollama-image, allowlist-identities-published.
  - R4: emotion-coldstart-vs-timeout, embeddings-autostop, internal-url-guidance-contradicts-deploy, anthropic-error-observability.
  - R2: temperature-comment-mismatch, provider-label-mislabels-local, dead-default-arg, resolve-model-shadowed-names, redundant-restricted-guard, duplicated-bool-env-parsing, synthetic-flag-silently-noop, clinical-chain-contract-contradiction, chain-count-doc-inconsistency, docs-claim-private-network, session-revocation-doc-mismatch, stale-provider-list.
  - R3: synthetic-routing-unproved, demo-flag-silently-ignored, temperature-strip-narrow, restore-from-map-contract, sidecar-cold-start-vs-timeout, internal-urls-contradict-deploy, empty-demo-flag-crash.
- S2: sidecar posture, user choice "Token + auto-stop (Recomendado)": "Agrego un bearer token secreto en ambos sidecars (Ollama vía proxy liviano) y subo el timeout de la app para tolerar el arranque en frío. Sigue costando ~0 en reposo. Requiere redeploy en Fly."
  - Health endpoints stay unauthenticated, because Fly checks call them without a token.
  - Assumption: the tokens are optional in app config (no header when unset), so local dev and the current deploy keep working until the secrets are staged.
  - Redeploying to Fly needs separate, explicit user authorization.

## Tasks

- T1 [S1,S2] inline; done; commit `2373a46`. Sidecar bearer auth (emotion `server.py`, Ollama behind a Caddy proxy with a pinned image), app clients send the token, cold-start-tolerant timeouts. Risk: items 2 and 5.
- T2 [S1] inline; done; commit `ffb8b73`. Code findings: Anthropic adapter, guided chain attribution, llm_config naming, admission guard, runtime flag parsing, chain contract docs, routed-chain test.
- T3 [S1,S2] inline; done; commit: docs slice. Docs match the deployed posture, and the demo identities are removed from the task log.

## Log

- L1 (2026-10-26): "arreglemos todo"
- L2 (2026-10-26): The user chose "Token + auto-stop (Recomendado)" for the sidecars.
- L3: Exploration findings:
  - Neither sidecar client sends auth.
  - Embeddings has no prod timeout env (120s default). Emotion's receive timeout is 30s.
  - The app health check never pings the sidecars.
  - Ollama runs `ollama/ollama:latest` with no Dockerfile. Pin it to `0.40.11`.
  - The six routed chains parse JSON from text (`StructuredOutput.parse_json_response`) and use no tools, so the AnthropicChat tool rejection does not block them.
  - `supported_providers/0` is never enforced at runtime.
- L4: T1 done.
  - RED, then GREEN: sidecar python 10/10; client header tests; runtime config 47/47.
  - Caddy proxy checked against a fake upstream: no token gets 401; pull/delete/generate get 401 even with a valid token; embed with a token gets 200; `GET /` gets 200.
  - Found `EmotionAnalysisWorker` `max_attempts: 1`, so the sidecar now binds first and holds batches during load instead of relying on retries.
  - The demo-flag parsing (R2/R3 findings) landed in this commit because it shares `config/runtime.exs`.
  - Not run: a container build (Docker daemon unavailable) and the Fly redeploy (needs authorization).
- L5: T2 done. `mix precommit`: 2169 passed, 5 skipped.
  - `synthetic_demo_routing_test` proves all six routed chains are tool-free through AnthropicChat. It is a characterization test: it passed on first run.
  - Gap: cloud (OpenAI) `model_version` has no test, because LLMConfig exposes no request stub for ChatOpenAI.
- L6: T3 done.
  - Docs now describe public sidecars with tokens, auto-stop, cold-start timeouts, the 6 routed chains, the actual revocation behavior and the 3 provider values.
  - Demo identities were removed from the task log, but they remain in git history.
  - R1-public-* is resolved by S2: token gate plus the Ollama API allowlist.
