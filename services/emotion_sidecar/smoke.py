import json
import os
import urllib.request


def main():
    base_url = os.environ.get("EMOTION_SIDECAR_URL", "http://127.0.0.1:8080")
    body = json.dumps({"texts": ["Hoy recibí una noticia sintética agradable."]}).encode()
    request = urllib.request.Request(
        base_url.rstrip("/") + "/v1/emotions:batch",
        data=body,
        headers={"Content-Type": "application/json"},
        method="POST",
    )

    with urllib.request.urlopen(request, timeout=60) as response:
        result = json.loads(response.read())["results"][0]

    print(json.dumps({"label": result["label"], "scores": result["scores"]}, sort_keys=True))


if __name__ == "__main__":
    main()
