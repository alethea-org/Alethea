import argparse
import json
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from numbers import Number


MAX_BATCH_SIZE = 32
MAX_BODY_BYTES = 256 * 1024
MAX_TEXT_BYTES = 4096
OFFICIAL_LABELS = {
    "others",
    "joy",
    "sadness",
    "anger",
    "surprise",
    "disgust",
    "fear",
}


def create_official_analyzer():
    from pysentimiento import create_analyzer

    return create_analyzer(task="emotion", lang="es")


class EmotionRuntime:
    def __init__(self, analyzer_factory):
        self.inference_gate = threading.BoundedSemaphore(value=1)
        try:
            self.analyzer = analyzer_factory()
        except Exception:
            self.analyzer = None

    def predict(self, texts):
        if self.analyzer is None:
            raise AnalyzerUnavailable()
        if not self.inference_gate.acquire(blocking=False):
            raise AnalyzerBusy()

        try:
            outputs = self.analyzer.predict(texts)
            if not isinstance(outputs, list) or len(outputs) != len(texts):
                raise AnalyzerUnavailable()
            return [serialize_output(output) for output in outputs]
        except AnalyzerUnavailable:
            raise
        except Exception as error:
            raise AnalyzerUnavailable() from error
        finally:
            self.inference_gate.release()


class AnalyzerUnavailable(Exception):
    pass


class AnalyzerBusy(Exception):
    pass


def serialize_output(output):
    label = getattr(output, "output", None)
    raw_scores = getattr(output, "probas", None)
    if label not in OFFICIAL_LABELS or not isinstance(raw_scores, dict):
        raise AnalyzerUnavailable()
    if set(raw_scores) != OFFICIAL_LABELS:
        raise AnalyzerUnavailable()

    scores = {}
    for score_label, score in raw_scores.items():
        if (
            isinstance(score, bool)
            or not isinstance(score, Number)
            or not 0.0 <= float(score) <= 1.0
        ):
            raise AnalyzerUnavailable()
        scores[score_label] = float(score)

    return {"label": label, "scores": scores}


class EmotionHTTPServer(ThreadingHTTPServer):
    daemon_threads = True
    request_queue_size = 16

    def __init__(self, server_address, runtime):
        self.runtime = runtime
        super().__init__(server_address, EmotionRequestHandler)


class EmotionRequestHandler(BaseHTTPRequestHandler):
    server_version = "AletheaEmotionSidecar/1"

    def do_GET(self):
        if self.path == "/health/live":
            self.send_json(200, {"status": "ok"})
        elif self.path == "/health/ready":
            if self.server.runtime.analyzer is None:
                self.send_error_json(503, "analyzer_unavailable", "Analyzer is unavailable")
            else:
                self.send_json(200, {"status": "ready"})
        else:
            self.send_error_json(404, "not_found", "Endpoint not found")

    def do_POST(self):
        if self.path != "/v1/emotions:batch":
            self.send_error_json(404, "not_found", "Endpoint not found")
            return

        payload = self.read_json_body()
        if payload is None:
            return

        texts = payload.get("texts") if isinstance(payload, dict) else None
        validation_error = validate_texts(texts)
        if validation_error:
            code, message = validation_error
            self.send_error_json(422, code, message)
            return

        try:
            results = self.server.runtime.predict(texts)
            self.send_json(200, {"version": "v1", "results": results})
        except AnalyzerBusy:
            self.send_error_json(503, "busy", "Analyzer is busy")
        except AnalyzerUnavailable:
            self.send_error_json(503, "analyzer_unavailable", "Analyzer is unavailable")

    def read_json_body(self):
        content_length = self.headers.get("Content-Length")
        try:
            length = int(content_length)
        except (TypeError, ValueError):
            self.send_error_json(400, "invalid_content_length", "Content-Length is required")
            return None

        if length < 1:
            self.send_error_json(400, "invalid_json", "JSON body is required")
            return None
        if length > MAX_BODY_BYTES:
            self.send_error_json(413, "body_too_large", "Request body is too large")
            return None

        try:
            return json.loads(self.rfile.read(length))
        except (UnicodeDecodeError, json.JSONDecodeError):
            self.send_error_json(400, "invalid_json", "Request body must be valid JSON")
            return None

    def send_error_json(self, status, code, message):
        self.send_json(status, {"error": {"code": code, "message": message}})

    def send_json(self, status, payload):
        body = json.dumps(payload, separators=(",", ":")).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, _format, *_args):
        # Do not log request paths, inputs, or bodies from clinical traffic.
        return


def validate_texts(texts):
    if not isinstance(texts, list) or not 1 <= len(texts) <= MAX_BATCH_SIZE:
        return "invalid_batch_size", f"Batch size must be between 1 and {MAX_BATCH_SIZE}"

    for text in texts:
        if not isinstance(text, str) or not text:
            return "invalid_text", "Every text must be a non-empty string"
        if len(text.encode("utf-8")) > MAX_TEXT_BYTES:
            return "text_too_large", f"Every text must be at most {MAX_TEXT_BYTES} bytes"

    return None


def create_server(host, port, analyzer_factory=create_official_analyzer):
    return EmotionHTTPServer((host, port), EmotionRuntime(analyzer_factory))


def main():
    parser = argparse.ArgumentParser(description="Alethea internal emotion sidecar")
    parser.add_argument("--host", default="0.0.0.0")
    parser.add_argument("--port", type=int, default=8080)
    args = parser.parse_args()

    server = create_server(args.host, args.port)
    try:
        server.serve_forever()
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
