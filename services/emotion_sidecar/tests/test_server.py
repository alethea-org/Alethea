import json
import threading
import unittest
import urllib.error
import urllib.request

from services.emotion_sidecar.server import (
    MAX_BATCH_SIZE,
    MAX_BODY_BYTES,
    MAX_TEXT_BYTES,
    create_server,
)


SCORES = {
    "others": 0.05,
    "joy": 0.70,
    "sadness": 0.05,
    "anger": 0.05,
    "surprise": 0.05,
    "disgust": 0.05,
    "fear": 0.05,
}


class FakeOutput:
    def __init__(self, label="joy", scores=None):
        self.output = label
        self.probas = scores or SCORES


class FakeAnalyzer:
    def __init__(self, outputs=None):
        self.outputs = outputs
        self.calls = []

    def predict(self, texts):
        self.calls.append(texts)
        return self.outputs or [FakeOutput() for _text in texts]


class RunningServer:
    def __init__(self, factory):
        self.server = create_server("127.0.0.1", 0, analyzer_factory=factory)
        self.thread = threading.Thread(
            target=lambda: self.server.serve_forever(poll_interval=0.01), daemon=True
        )
        self.thread.start()
        host, port = self.server.server_address
        self.base_url = f"http://{host}:{port}"

    def close(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=2)

    def request(self, path, payload=None):
        data = None if payload is None else json.dumps(payload).encode("utf-8")
        request = urllib.request.Request(
            self.base_url + path,
            data=data,
            headers={"Content-Type": "application/json"},
            method="POST" if data is not None else "GET",
        )

        try:
            response = urllib.request.urlopen(request, timeout=2)
            return response.status, json.loads(response.read())
        except urllib.error.HTTPError as error:
            status = error.code
            body = json.loads(error.read())
            error.close()
            return status, body

    def request_raw(self, path, body):
        request = urllib.request.Request(
            self.base_url + path,
            data=body,
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        try:
            response = urllib.request.urlopen(request, timeout=2)
            return response.status, json.loads(response.read())
        except urllib.error.HTTPError as error:
            status = error.code
            payload = json.loads(error.read())
            error.close()
            return status, payload


class EmotionSidecarHTTPTest(unittest.TestCase):
    def tearDown(self):
        if hasattr(self, "running"):
            self.running.close()

    def start(self, factory):
        self.running = RunningServer(factory)
        return self.running

    def test_liveness_and_readiness_create_analyzer_once(self):
        analyzer = FakeAnalyzer()
        factory_calls = []

        server = self.start(lambda: factory_calls.append(True) or analyzer)

        self.assertEqual(server.request("/health/live"), (200, {"status": "ok"}))
        self.assertEqual(server.request("/health/ready"), (200, {"status": "ready"}))
        self.assertEqual(factory_calls, [True])

    def test_batch_success_uses_one_predict_call_and_omits_inputs(self):
        analyzer = FakeAnalyzer()
        server = self.start(lambda: analyzer)

        status, body = server.request(
            "/v1/emotions:batch", {"texts": ["Synthetic joy", "Synthetic calm"]}
        )

        self.assertEqual(status, 200)
        self.assertEqual(len(body["results"]), 2)
        self.assertEqual(body["results"][0], {"label": "joy", "scores": SCORES})
        self.assertEqual(analyzer.calls, [["Synthetic joy", "Synthetic calm"]])
        self.assertNotIn("texts", body)

    def test_batch_rejects_cardinality_and_text_limits(self):
        server = self.start(FakeAnalyzer)

        cases = [
            ({"texts": []}, "invalid_batch_size"),
            ({"texts": ["x"] * (MAX_BATCH_SIZE + 1)}, "invalid_batch_size"),
            ({"texts": ["x" * (MAX_TEXT_BYTES + 1)]}, "text_too_large"),
        ]

        for payload, code in cases:
            with self.subTest(code=code):
                status, body = server.request("/v1/emotions:batch", payload)
                self.assertEqual(status, 422)
                self.assertEqual(body["error"]["code"], code)

    def test_batch_rejects_analyzer_cardinality_mismatch(self):
        server = self.start(lambda: FakeAnalyzer(outputs=[FakeOutput()]))

        status, body = server.request(
            "/v1/emotions:batch", {"texts": ["Synthetic one", "Synthetic two"]}
        )

        self.assertEqual(status, 503)
        self.assertEqual(body["error"]["code"], "analyzer_unavailable")

    def test_batch_rejects_body_byte_limit_before_parsing(self):
        server = self.start(FakeAnalyzer)

        status, body = server.request_raw(
            "/v1/emotions:batch", b"x" * (MAX_BODY_BYTES + 1)
        )

        self.assertEqual(status, 413)
        self.assertEqual(body["error"]["code"], "body_too_large")

    def test_readiness_and_batch_fail_when_factory_fails(self):
        def failing_factory():
            raise RuntimeError("synthetic startup failure")

        server = self.start(failing_factory)

        self.assertEqual(server.request("/health/ready")[0], 503)
        status, body = server.request("/v1/emotions:batch", {"texts": ["Synthetic"]})
        self.assertEqual(status, 503)
        self.assertEqual(body["error"]["code"], "analyzer_unavailable")

    def test_concurrent_batch_fails_fast_as_busy(self):
        entered = threading.Event()
        release = threading.Event()

        class BlockingAnalyzer(FakeAnalyzer):
            def predict(self, texts):
                entered.set()
                release.wait(timeout=2)
                return super().predict(texts)

        server = self.start(BlockingAnalyzer)
        first_result = []
        first = threading.Thread(
            target=lambda: first_result.append(
                server.request("/v1/emotions:batch", {"texts": ["Synthetic first"]})
            )
        )
        first.start()
        self.assertTrue(entered.wait(timeout=1))

        status, body = server.request(
            "/v1/emotions:batch", {"texts": ["Synthetic second"]}
        )
        self.assertEqual(status, 503)
        self.assertEqual(body["error"]["code"], "busy")

        release.set()
        first.join(timeout=2)
        self.assertEqual(first_result[0][0], 200)


if __name__ == "__main__":
    unittest.main()
