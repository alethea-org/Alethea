FROM python:3.11.9-slim-bookworm

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    HF_HOME=/home/sidecar/.cache/huggingface

RUN useradd --create-home --uid 10001 sidecar

WORKDIR /app
COPY requirements.txt ./
RUN python -m pip install --no-cache-dir --requirement requirements.txt

COPY --chown=sidecar:sidecar . ./services/emotion_sidecar/
USER sidecar

EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=5s --start-period=240s --retries=5 \
  CMD ["python", "-c", "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8080/health/ready', timeout=2)"]

CMD ["python", "-m", "services.emotion_sidecar.server", "--host", "0.0.0.0", "--port", "8080"]
