# Emotion Sidecar

Internal Python 3.11 HTTP runtime for Spanish emotion-only inference through the
official `pysentimiento.create_analyzer(task="emotion", lang="es")` integration.
The analyzer is created once at process startup and `predict(texts)` handles each
bounded batch without manual tweet preprocessing.

## Usage restriction

`pysentimiento` and the selected model are restricted to non-commercial,
scientific/research use. This integration is approved only for Alethea's academic
and demonstration use. Review upstream terms before any commercial deployment.

## Runtime contract

- `GET /health/live` reports process liveness.
- `GET /health/ready` reports whether the analyzer loaded successfully
  (`503 analyzer_loading` while the model loads in the background).
- `POST /v1/emotions:batch` accepts `{"texts": [...]}` with 1 to 32 non-empty
  strings, at most 4096 UTF-8 bytes each.
- Batches require `Authorization: Bearer <token>` matching `SIDECAR_AUTH_TOKEN`
  (`401 unauthorized` otherwise). The server refuses to start without a token
  unless `SIDECAR_AUTH_DISABLED=true` (local use; `docker-compose.yml` sets it).
  Health endpoints stay open.
- If the model fails to load, the process exits so the platform restarts it.
- One request runs inference at a time. On a warm sidecar, concurrent inference
  fails fast with a stable `busy` error instead of creating an unbounded queue.
  The exception is a cold start: batches that arrived while the model loaded
  wait for it and then queue for the inference slot, within a shared 240 s
  budget.
- Responses contain only official labels and scores. Inputs and bodies are never
  logged or echoed.

## Reproducibility

`requirements.txt` pins `pysentimiento 0.7.3` and the compatible official runtime
set: CPU-only PyTorch 2.2.1, Transformers 4.38.2, spaCy 3.7.4, Datasets 2.18.0,
and Accelerate 0.27.2. NumPy is pinned below 2 for PyTorch 2.2 compatibility. The
Docker base is pinned to Python 3.11.9 on Debian Bookworm slim.

The image build installs packages but does not download model weights. The model
is downloaded by the official analyzer on first container startup and retained
in the Compose `emotion_model_cache` volume. Compose permits 240 seconds before
readiness failures to accommodate the observed approximately 210-second cold
model startup.

## Tests and opt-in smoke

Unit tests use a fake analyzer and require no third-party Python packages:

```sh
python3 -m unittest discover -s services/emotion_sidecar/tests -v
```

After explicitly installing dependencies and starting the sidecar, run the real
synthetic smoke separately from the normal suite:

```sh
EMOTION_SIDECAR_URL=http://127.0.0.1:8080 python3 services/emotion_sidecar/smoke.py
```

The smoke sends one fixed synthetic sentence and prints only the resulting label
and scores. It never sends or reports clinical data.
