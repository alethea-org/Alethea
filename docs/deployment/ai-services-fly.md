# AI Services Deployment Readiness on Fly.io (Synthetic Demo Profile)

> **Status: Readiness, sizing, and architecture complete. Actual provisioning is GATED on user cost consent (S4).**
> Do not execute the provisioning commands in this document without explicit authorization and agreed budget.
> Scope: Synthetic clinical demonstration on Fly.io (`feat/synthetic-demo-ai`, T3 under S2 and S4). Real patient data is strictly prohibited.

---

## 1. Overview & Architecture

To satisfy S2 ("todas las pantallas tienen que funcionar, todos los servicios tienen que funcionar") without running local models on developer laptops, Alethea requires two auxiliary AI runtimes alongside the main web application (`alethea-prod`):

1. **Embeddings Service (`alethea-embeddings`)**: Ollama running `BAAI/bge-m3` for multilingual, 1024-dimensional semantic embeddings used by RAG retrieval (`Alethea.AI.Embeddings.Ollama`).
2. **Emotion Sidecar (`alethea-emotion`)**: Python 3.11 / PyTorch CPU microservice running `pysentimiento` for Spanish emotion analysis (`Alethea.AI.EmotionAnalyzer`).

### Zero-Egress Private Networking (`.internal`)

All communication between `alethea-prod` and the two AI sidecars takes place entirely over Fly.io's private WireGuard mesh network (6PN):

- **No public IP addresses** are allocated to the AI sidecars (`fly ips allocate-v4` and `allocate-v6` are never run).
- Endpoints use Fly private DNS: `http://<app-name>.internal:<port>`.
- Internal network traffic is encrypted, has zero bandwidth egress cost, and cannot be reached from the public internet.
- All apps are deployed in region **`gru` (São Paulo)** alongside `alethea-prod` and AWS `sa-east-1` (Neon PostgreSQL) for sub-millisecond local network latency.

```
                      +-------------------------------------------------------+
                      |                      Fly.io (gru)                     |
                      |                                                       |
[Public Internet] --> | [alethea-prod] (Port 4000)                            |
                      |   |                                                   |
                      |   |-- (http://alethea-embeddings.internal:11434) ---> | [alethea-embeddings] (Ollama + bge-m3)
                      |   |                                                   |   NVMe Volume: 10 GB (/root/.ollama)
                      |   |                                                   |
                      |   +-- (http://alethea-emotion.internal:8080) -------> | [alethea-emotion] (pysentimiento)
                      |                                                       |   NVMe Volume: 5 GB (/home/sidecar/.cache)
                      +-------------------------------------------------------+
```

---

## 2. BGE-M3 Embeddings Service (`alethea-embeddings`)

### Specification & Contract

- **Model**: `BAAI/bge-m3` (multilingual, 1024-dimension vector output).
- **Elixir Adapter**: `Alethea.AI.Embeddings.Ollama` (`lib/alethea/ai/embeddings/ollama.ex`).
- **Endpoint**: `http://alethea-embeddings.internal:11434/api/embed`.
- **Dimensionality**: Fixed at 1024 dimensions, exactly matching the `vector(1024)` column in PostgreSQL `clinical_embeddings`.

### Sizing Justification

- **Model size on disk**: ~2.2 GB (quantized GGUF in Ollama format).
- **RAM footprint**: Ollama base daemon (~100 MB) + loaded BGE-M3 model weights in memory (~2.4 GB) + inference buffer (~500 MB) = ~3.0 GB active RAM.
- **Recommended Fly Machine**: `shared-cpu-2x` with **4 GB RAM** (or `performance-1x` 4 GB if higher concurrency is needed).
- **Persistent Volume**: **10 GB NVMe** attached at `/root/.ollama`. This ensures `bge-m3` is downloaded only once during initial setup and is preserved across machine restarts, updates, and sleep cycles.

### Environment Configuration on `alethea-prod`

When enabled, stage the following variables on `alethea-prod`:

| Variable | Value | Description |
| --- | --- | --- |
| `EMBEDDINGS_ENABLED` | `true` | Activates `Alethea.AI.Embeddings.Ollama` instead of `Disabled`. |
| `EMBEDDINGS_BASE_URL` | `http://alethea-embeddings.internal:11434` | Private 6PN URL reachable from `alethea-prod`. |
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
- **Endpoint**: `http://alethea-emotion.internal:8080/v1/emotions:batch`.
- **Health Checks**: `GET /health/live` (process alive) and `GET /health/ready` (model weights loaded and warm).
- **Batch limits**: 1 to 32 texts per request, max 4096 bytes per text.

### Sizing Justification

- **Model size on disk**: ~440 MB Hugging Face cache.
- **RAM footprint**: Python 3.11 + PyTorch CPU runtime (~600 MB) + `pysentimiento` model in memory (~600 MB) + batch processing headroom = ~1.4 - 1.8 GB active RAM.
- **Cold startup time**: Observed cold startup is ~210 seconds while the model compiles and initializes.
- **Recommended Fly Machine**: `shared-cpu-2x` with **4 GB RAM** (gives sufficient breathing room against out-of-memory spikes during cold model loading).
- **Persistent Volume**: **5 GB NVMe** attached at `/home/sidecar/.cache/huggingface` so downloaded Hugging Face weights survive container restarts.

### Environment Configuration on `alethea-prod`

When enabled, stage the following variables on `alethea-prod`:

| Variable | Value | Description |
| --- | --- | --- |
| `EMOTION_ANALYZER_ENABLED` | `true` | Activates `Alethea.AI.EmotionAnalyzer` instead of `Disabled`. |
| `EMOTION_SIDECAR_URL` | `http://alethea-emotion.internal:8080` | Private 6PN URL reachable from `alethea-prod`. |
| `EMOTION_SIDECAR_RECEIVE_TIMEOUT_MS` | `30000` *(optional)* | Timeout in ms (defaults to 30,000 in `runtime.exs`). |
| `EMOTION_SIDECAR_CONNECT_TIMEOUT_MS` | `2000` *(optional)* | Connect timeout in ms (defaults to 2,000 in `runtime.exs`). |

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

1. **Strictly Non-Commercial Academic/Demonstration Scope**: The target audience is the academic evaluator ("a mí y al profe", S3). This directly adheres to `pysentimiento`'s non-commercial research licensing terms.
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

*Note: All prices are estimates based on standard Fly.io compute and storage rates as of 2025/2026. Data transfer over 6PN (`.internal`) is $0.00.*

---

## 6. Provisioning Runbook (Gated on User Cost Consent - S4)

> **DO NOT EXECUTE THESE COMMANDS WITHOUT EXPLICIT USER CONSENT.**
> These commands are cataloged here so that once cost consent (S4) is granted, deployment is deterministic, reproducible, and rapid.

### Phase A: Provision Embeddings App (`alethea-embeddings`)

```sh
# 1. Create the Fly application (no public IPs)
fly apps create alethea-embeddings --org <your-org>

# 2. Create the 10GB persistent volume in São Paulo (gru)
fly volumes create ollama_data --app alethea-embeddings --region gru --size 10 --yes

# 3. Create fly.toml for alethea-embeddings:
cat <<'EOF' > fly.embeddings.toml
app = "alethea-embeddings"
primary_region = "gru"

[build]
  image = "ollama/ollama:latest"

[mounts]
  source = "ollama_data"
  destination = "/root/.ollama"

[env]
  OLLAMA_HOST = "0.0.0.0:11434"

[[services]]
  internal_port = 11434
  protocol = "tcp"
  auto_stop_machines = "off"
  auto_start_machines = true
  min_machines_running = 1

[[vm]]
  size = "shared-cpu-2x"
  memory = "4gb"
EOF

# 4. Deploy the embeddings app
fly deploy --config fly.embeddings.toml --ha=false

# 5. Pull the bge-m3 model into the persistent volume (one-time operation)
fly ssh console -a alethea-embeddings -C "ollama pull bge-m3"

# 6. Verify model embedding output locally via 6PN proxy
fly ssh console -a alethea-embeddings -C 'curl -s http://localhost:11434/api/embed -d "{\"model\": \"bge-m3\", \"input\": \"Hola mundo\"}"'
```

### Phase B: Provision Emotion Sidecar App (`alethea-emotion`)

```sh
# 1. Create the Fly application (no public IPs)
fly apps create alethea-emotion --org <your-org>

# 2. Create the 5GB persistent volume in São Paulo (gru)
fly volumes create emotion_cache --app alethea-emotion --region gru --size 5 --yes

# 3. Create fly.toml for alethea-emotion:
cat <<'EOF' > fly.emotion.toml
app = "alethea-emotion"
primary_region = "gru"

[build]
  dockerfile = "services/emotion_sidecar/Dockerfile"

[mounts]
  source = "emotion_cache"
  destination = "/home/sidecar/.cache/huggingface"

[[services]]
  internal_port = 8080
  protocol = "tcp"
  auto_stop_machines = "off"
  auto_start_machines = true
  min_machines_running = 1

  [[services.http_checks]]
    interval = "30s"
    timeout = "5s"
    grace_period = "240s"
    method = "GET"
    path = "/health/ready"

[[vm]]
  size = "shared-cpu-2x"
  memory = "4gb"
EOF

# 4. Deploy the emotion sidecar from repository context
fly deploy --config fly.emotion.toml --ha=false

# 5. Verify sidecar readiness
fly ssh console -a alethea-emotion -C "curl -s http://localhost:8080/health/ready"
```

### Phase C: Wire `alethea-prod` to Auxiliary AI Services

```sh
# Stage the AI capability variables on alethea-prod
fly secrets set --stage -a alethea-prod \
  EMBEDDINGS_ENABLED="true" \
  EMBEDDINGS_BASE_URL="http://alethea-embeddings.internal:11434" \
  EMOTION_ANALYZER_ENABLED="true" \
  EMOTION_SIDECAR_URL="http://alethea-emotion.internal:8080"

# Trigger a rolling deploy of alethea-prod to consume the new staged configuration
fly deploy --ha=false
```
