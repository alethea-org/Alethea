# AI Services on Fly.io (Synthetic Demo Profile)

> **Status: deployed** as `alethea-embeddings` and `alethea-emotion` in `gru` (`feat/synthetic-demo-ai`, T3/T5).
> Scope: synthetic clinical demonstration only. Real patient data is strictly prohibited.

---

## 1. Overview & Architecture

To satisfy S2 ("todas las pantallas tienen que funcionar, todos los servicios tienen que funcionar") without running local models on developer laptops, Alethea runs two auxiliary AI runtimes alongside the main web application (`alethea-prod`):

1. **Embeddings Service (`alethea-embeddings`)**: Ollama running `BAAI/bge-m3` for multilingual, 1024-dimensional semantic embeddings used by RAG retrieval (`Alethea.AI.Embeddings.Ollama`).
2. **Emotion Sidecar (`alethea-emotion`)**: Python 3.11 / PyTorch CPU microservice running `pysentimiento` for Spanish emotion analysis (`Alethea.AI.EmotionAnalyzer`).

### Public endpoints with bearer tokens

Both sidecars are **public** Fly apps reached through their `fly.dev` hosts over TLS, and **auto-stop** when idle (user decision for the demo). Private 6PN (`.internal`) was tried first and dropped: it resolves IPv6-only and has no DNS while a machine is stopped, so it breaks auto-start.

Because they are public, inference is gated by a shared secret sent as `Authorization: Bearer <token>`:

| Sidecar | Secret on the sidecar | Secret on `alethea-prod` | Open without token |
| --- | --- | --- | --- |
| `alethea-embeddings` | `OLLAMA_AUTH_TOKEN` | `EMBEDDINGS_AUTH_TOKEN` | `GET /` (health) |
| `alethea-emotion` | `SIDECAR_AUTH_TOKEN` | `EMOTION_SIDECAR_AUTH_TOKEN` | `GET /health/live`, `GET /health/ready` |

- Ollama has no native auth. `deploy/embeddings/` runs a pinned Ollama on loopback behind a Caddy proxy that forwards only `GET /` and token-authenticated `POST /api/embed`. Model pull/delete/create/generate are unreachable from outside the machine. The entrypoint refuses to start without a token.
- The emotion sidecar checks the token itself (`services/emotion_sidecar/server.py`, constant-time compare). Without `SIDECAR_AUTH_TOKEN` it accepts every batch, which is meant for local development only.
- Generate each token with `openssl rand -hex 32`, and stage the same value on both sides.
- Traffic leaves Fly's private network, so egress is billed (negligible at demo volume). Sanitized clinical text travels over TLS.

### Cold starts

A stopped sidecar must boot and load its model before it answers (~210 s observed for the emotion sidecar). `fly.toml` on `alethea-prod` sets 300 s receive timeouts for both sidecars, and a 10 s connect timeout for the emotion sidecar. The emotion sidecar binds its port first, then loads the model in the background. A batch that arrives meanwhile is held for up to 280 s rather than refused, because `EmotionAnalysisWorker` runs a single attempt.

```
[Public Internet] --> [alethea-prod] (Port 4000)
                         |
                         |-- https://alethea-embeddings.fly.dev  (Bearer) --> Caddy :8080 --> Ollama 127.0.0.1:11434 (bge-m3)
                         |                                                     Volume: 10 GB (/root/.ollama)
                         |
                         +-- https://alethea-emotion.fly.dev     (Bearer) --> server.py :8080 (pysentimiento)
                                                                               Volume: 5 GB (/home/sidecar/.cache)
```

---

## 2. BGE-M3 Embeddings Service (`alethea-embeddings`)

### Specification & Contract

- **Model**: `BAAI/bge-m3` (multilingual, 1024-dimension vector output).
- **Elixir Adapter**: `Alethea.AI.Embeddings.Ollama` (`lib/alethea/ai/embeddings/ollama.ex`).
- **Endpoint**: `https://alethea-embeddings.fly.dev/api/embed` (bearer token required).
- **Image**: `deploy/embeddings/Dockerfile`: `ollama/ollama:0.40.11` plus Caddy 2.11.7, both pinned.
- **Dimensionality**: Fixed at 1024 dimensions, exactly matching the `vector(1024)` column in PostgreSQL `clinical_embeddings`.

### Sizing Justification

- **Model size on disk**: ~2.2 GB (quantized GGUF in Ollama format).
- **RAM footprint**: Ollama base daemon (~100 MB) + loaded BGE-M3 model weights in memory (~2.4 GB) + inference buffer (~500 MB) = ~3.0 GB active RAM.
- **Recommended Fly Machine**: `shared-cpu-2x` with **4 GB RAM** (or `performance-1x` 4 GB if higher concurrency is needed).
- **Persistent Volume**: **10 GB NVMe** attached at `/root/.ollama`. This ensures `bge-m3` is downloaded only once during initial setup and is preserved across machine restarts, updates, and sleep cycles.

### Environment Configuration on `alethea-prod`

| Variable | Value | Description |
| --- | --- | --- |
| `EMBEDDINGS_ENABLED` | `true` | Activates `Alethea.AI.Embeddings.Ollama` instead of `Disabled`. |
| `EMBEDDINGS_BASE_URL` | `https://alethea-embeddings.fly.dev` | Public Fly host (auto-starts the machine). |
| `EMBEDDINGS_AUTH_TOKEN` | secret | Same value as `OLLAMA_AUTH_TOKEN` on `alethea-embeddings`. Optional in config; no header is sent when unset. |
| `EMBEDDINGS_RECEIVE_TIMEOUT_MS` | `300000` (set in `fly.toml`) | Defaults to 120,000. Raised to wait out a cold start. |
| `EMBEDDINGS_MODEL` | `bge-m3` *(optional)* | Defaults to `bge-m3` in the adapter if omitted. |

### Cost Breakdown (Estimated)

- **Compute (`shared-cpu-2x`, 4 GB RAM)**:
  - Hourly: ~$0.0164 / hour.
  - Always-on (730 hrs/month): **~$12.00 / month**.
- **Storage (10 GB NVMe Volume)**:
  - $0.15 / GB / month: **$1.50 / month**.
- **Total Embeddings Cost**: **~$13.50 / month** (or ~$1.50/mo storage + pennies per demo session if machine auto-stops when idle).

---

## 3. Spanish Emotion Analyzer Sidecar (`alethea-emotion`)

### Specification & Contract

- **Model / Library**: `pysentimiento` 0.7.3 (`robertuito-emotion-analysis`, ~440 MB weights) with PyTorch CPU 2.2.1 and Transformers 4.38.2.
- **Artifact**: `services/emotion_sidecar/Dockerfile` (Debian 12 slim base, non-root user `sidecar:sidecar`, port 8080).
- **Elixir Adapter**: `Alethea.AI.EmotionAnalyzer` (`lib/alethea/ai/emotion_analyzer.ex`).
- **Endpoint**: `https://alethea-emotion.fly.dev/v1/emotions:batch` (bearer token required when `SIDECAR_AUTH_TOKEN` is set).
- **Health Checks**: `GET /health/live` (process alive) and `GET /health/ready` (model loaded; `503 analyzer_loading` while it loads). Both are unauthenticated.
- **Batch limits**: 1 to 32 texts per request, max 4096 bytes per text.

### Sizing Justification

- **Model size on disk**: ~440 MB Hugging Face cache.
- **RAM footprint**: Python 3.11 + PyTorch CPU runtime (~600 MB) + `pysentimiento` model in memory (~600 MB) + batch processing headroom = ~1.4 - 1.8 GB active RAM.
- **Cold startup time**: Observed cold startup is ~210 seconds while the model compiles and initializes.
- **Recommended Fly Machine**: `shared-cpu-2x` with **4 GB RAM** (gives sufficient breathing room against out-of-memory spikes during cold model loading).
- **Persistent Volume**: **5 GB NVMe** attached at `/home/sidecar/.cache/huggingface` so downloaded Hugging Face weights survive container restarts.

### Environment Configuration on `alethea-prod`

| Variable | Value | Description |
| --- | --- | --- |
| `EMOTION_ANALYZER_ENABLED` | `true` | Activates `Alethea.AI.EmotionAnalyzer` instead of `Disabled`. |
| `EMOTION_SIDECAR_URL` | `https://alethea-emotion.fly.dev` | Public Fly host (auto-starts the machine). |
| `EMOTION_SIDECAR_AUTH_TOKEN` | secret | Same value as `SIDECAR_AUTH_TOKEN` on `alethea-emotion`. Optional in config; no header is sent when unset. |
| `EMOTION_SIDECAR_RECEIVE_TIMEOUT_MS` | `300000` (set in `fly.toml`) | Defaults to 30,000. Raised to wait out a cold start. |
| `EMOTION_SIDECAR_CONNECT_TIMEOUT_MS` | `10000` (set in `fly.toml`) | Defaults to 2,000. |

### Cost Breakdown (Estimated)

- **Compute (`shared-cpu-2x`, 4 GB RAM)**:
  - Hourly: ~$0.0164 / hour.
  - Always-on (730 hrs/month): **~$12.00 / month** (or ~$7.12/mo if scaled to 2 GB).
- **Storage (5 GB NVMe Volume)**:
  - $0.15 / GB / month: **$0.75 / month**.
- **Total Emotion Sidecar Cost**: **~$12.75 / month** (or ~$0.75/mo storage + usage if auto-stopped).

---

## 4. Resolution of the Issue-198 Conflict

### The Conflict

In development, issue #198 explicitly stamped `Alethea.AI.EmotionAnalyzer` as a **development-only** capability:
- The underlying `pysentimiento` model is trained on social media text (Twitter/X Spanish) and carries **no clinical validity**, diagnostic reliability, or therapeutic benchmarking.
- Upstream licensing for `pysentimiento` is restricted to **non-commercial, scientific and academic research** only.
- In `docs/deployment/fly-neon.md`, enabling the emotion analyzer in production was listed as an open conflict with issue #198.

### Resolution for the Synthetic Demo Profile (S2, S3, S4)

The conflict is resolved specifically and exclusively for the synthetic demo profile under the following documented criteria:

1. **Strictly Non-Commercial Academic/Demonstration Scope**: The target audience is the academic evaluator ("a mí y al profe", S3). This directly adheres to `pysentimiento`'s non-commercial research licensing terms. The endpoint is public, but inference requires the bearer token held only by `alethea-prod`, so the model serves no one outside that scope.
2. **Exclusively Synthetic Patient Data**: Under `DEMO_SYNTHETIC_DATA=true` and restricted admission (`DEMO_RESTRICTED_ACCESS=true`), no real patients or genuine clinical histories are processed. No diagnostic harm or clinical consequence can occur.
3. **Fulfillment of S2**: Requirement S2 explicitly mandates: *"todas las pantallas tienen que funcionar, todos los servicios tienen que funcionar"*. Running the sidecar enables the emotion trends dashboard in the clinician interface without mock placeholders.
4. **Permanent Guardrail for Milestone 2**: This resolution applies **solely to the synthetic demo**. For any future production deployment with real patient data (milestone 2 of issue #402), enabling the emotion analyzer remains strictly forbidden until a clinically validated, commercially licensed model is integrated.

---

## 5. Total Infrastructure Budget & Cost Summary

| Service | Machine Spec | Storage | Monthly Cost (Always-On) | Monthly Cost (Auto-Stop On Idle) |
| --- | --- | --- | --- | --- |
| **Embeddings** (`bge-m3`) | `shared-cpu-2x` (4 GB) | 10 GB NVMe | ~$13.50 | ~$1.50 + ~$0.016/active hr |
| **Emotion Sidecar** | `shared-cpu-2x` (4 GB) | 5 GB NVMe | ~$12.75 | ~$0.75 + ~$0.016/active hr |
| **Main App** (`alethea-prod`) | `shared-cpu-1x` (1 GB) | None | ~$3.20 | ~$3.20 (must be always-on for Oban) |
| **Total Auxiliary AI** | — | **15 GB NVMe** | **~$26.25 / month** | **~$2.25/mo + active hours** |

*Note: All prices are estimates based on standard Fly.io compute and storage rates as of 2025/2026. The deployed posture is auto-stop; sidecar traffic goes over the public hosts, so it counts as (negligible) egress.*

---

## 6. Provisioning Runbook

> Remote operations: run these only with explicit authorization for the target app. Commands run from the repository root.

### Phase A: Embeddings (`alethea-embeddings`)

```sh
fly apps create alethea-embeddings --org <your-org>
fly volumes create ollama_data --app alethea-embeddings --region gru --size 10 --yes

# Token gate (Caddy refuses to start without it)
fly secrets set --stage -a alethea-embeddings OLLAMA_AUTH_TOKEN="$(openssl rand -hex 32)"

fly deploy deploy/embeddings -c deploy/fly.embeddings.toml --dockerfile deploy/embeddings/Dockerfile --ha=false

# One-time model pull into the volume (Ollama listens on loopback only)
fly ssh console -a alethea-embeddings -C "ollama pull bge-m3"
```

### Phase B: Emotion sidecar (`alethea-emotion`)

```sh
fly apps create alethea-emotion --org <your-org>
fly volumes create emotion_cache --app alethea-emotion --region gru --size 5 --yes
fly secrets set --stage -a alethea-emotion SIDECAR_AUTH_TOKEN="$(openssl rand -hex 32)"
fly deploy services/emotion_sidecar -c services/emotion_sidecar/fly.toml --ha=false
```

### Phase C: Wire `alethea-prod`

Read each sidecar token once, without echoing it (`read -s`), and stage it on `alethea-prod`:

```sh
fly secrets set --stage -a alethea-prod \
  EMBEDDINGS_ENABLED="true" \
  EMBEDDINGS_BASE_URL="https://alethea-embeddings.fly.dev" \
  EMBEDDINGS_AUTH_TOKEN="$EMBEDDINGS_TOKEN" \
  EMOTION_ANALYZER_ENABLED="true" \
  EMOTION_SIDECAR_URL="https://alethea-emotion.fly.dev" \
  EMOTION_SIDECAR_AUTH_TOKEN="$EMOTION_TOKEN"

fly deploy --ha=false
```

Order: deploy the app with the client tokens first (an unenforced sidecar ignores the header), then set the sidecar secrets and redeploy each sidecar. The reverse order fails every call with 401 until the app catches up.

### Verify

```sh
curl -s -o /dev/null -w '%{http_code}\n' -X POST https://alethea-embeddings.fly.dev/api/embed   # 401
curl -s -o /dev/null -w '%{http_code}\n' -X POST https://alethea-emotion.fly.dev/v1/emotions:batch # 401
curl -s https://alethea-emotion.fly.dev/health/ready                                              # {"status":"ready"} once warm
```
