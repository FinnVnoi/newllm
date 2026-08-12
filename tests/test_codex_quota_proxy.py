from __future__ import annotations

import json
import os
import sys
import threading
import unittest
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

import codex_quota_proxy as quota_proxy


SAMPLE_USAGE = {
    "request_count": 2958,
    "total_tokens": 348741802,
    "cached_input_tokens": 304903495,
    "total_cost_usd": 471.541148,
    "limits": [
        {
            "limit_type": "total_tokens",
            "limit_window": "lifetime",
            "max_value": 376666665,
            "current_value": 348752042,
            "remaining_value": 27914623,
            "model_filter": None,
            "reset_at": "9999-12-31T23:59:59.999999Z",
            "source": "api_key_limit",
        }
    ],
    "upstream_limits": [
        {
            "limit_type": "credits",
            "limit_window": "7d",
            "max_value": 120960,
            "current_value": 23058,
            "remaining_value": 97902,
            "model_filter": None,
            "reset_at": "2026-08-18T01:29:21Z",
            "source": "aggregate",
        }
    ],
}


class _FixtureHandler(BaseHTTPRequestHandler):
    def log_message(self, format_string, *args):
        pass

    def do_GET(self):
        if self.path == "/v1/usage":
            if self.headers.get("Authorization") != "Bearer test-key":
                self.send_error(401)
                return
            body = json.dumps(SAMPLE_USAGE).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        self.send_error(404)

    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(length)
        response_body = b"data: " + body + b"\n\n"
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Content-Length", str(len(response_body)))
        self.send_header("x-codex-primary-used-percent", "1")
        self.send_header("x-codex-primary-window-minutes", "300")
        self.end_headers()
        self.wfile.write(response_body)


class ProxyIntegrationTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.fixture = ThreadingHTTPServer(("127.0.0.1", 0), _FixtureHandler)
        cls.fixture_thread = threading.Thread(
            target=cls.fixture.serve_forever, daemon=True
        )
        cls.fixture_thread.start()
        fixture_port = cls.fixture.server_address[1]

        cls.settings = quota_proxy.Settings(
            host="127.0.0.1",
            port=quota_proxy.find_available_port("127.0.0.1", 49100),
            upstream_base_url=f"http://127.0.0.1:{fixture_port}/backend-api/codex",
            quota_url=f"http://127.0.0.1:{fixture_port}/v1/usage",
            api_key="test-key",
            local_token="local-test-token",
            refresh_seconds=60,
        )
        cls.proxy = quota_proxy.CodexQuotaProxyServer(cls.settings)
        cls.proxy.quota_cache.refresh()
        cls.proxy_thread = threading.Thread(target=cls.proxy.serve_forever, daemon=True)
        cls.proxy_thread.start()

    @classmethod
    def tearDownClass(cls):
        cls.proxy.shutdown()
        cls.proxy.server_close()
        cls.fixture.shutdown()
        cls.fixture.server_close()

    def test_lifetime_and_weekly_quota_are_added_as_native_headers(self):
        request = urllib.request.Request(
            f"http://127.0.0.1:{self.settings.port}/backend-api/codex/responses",
            data=b'{"model":"gpt-test"}',
            headers={"Authorization": "Bearer local-test-token"},
            method="POST",
        )
        with urllib.request.urlopen(request) as response:
            body = response.read()
            headers = {name.lower(): value for name, value in response.headers.items()}

        self.assertEqual(body, b'data: {"model":"gpt-test"}\n\n')
        self.assertAlmostEqual(
            float(headers["x-codex-primary-used-percent"]),
            348752042 / 376666665 * 100,
            places=5,
        )
        self.assertNotIn("x-codex-primary-window-minutes", headers)
        self.assertNotIn("x-codex-primary-reset-at", headers)
        self.assertAlmostEqual(
            float(headers["x-codex-secondary-used-percent"]),
            23058 / 120960 * 100,
            places=5,
        )
        self.assertEqual(headers["x-codex-secondary-window-minutes"], "10080")
        self.assertEqual(headers["x-codex-secondary-reset-at"], "1787016561")

    def test_health_does_not_expose_api_key(self):
        request = urllib.request.Request(
            f"http://127.0.0.1:{self.settings.port}{quota_proxy.HEALTH_PATH}",
            headers={"Authorization": "Bearer local-test-token"},
        )
        with urllib.request.urlopen(request) as response:
            payload = json.load(response)
        self.assertEqual(payload["service"], quota_proxy.PROXY_MARKER)
        self.assertNotIn("api_key", payload)

    def test_endpoint_helpers_preserve_provider_path(self):
        endpoint = "https://example.test:8443/backend-api/codex"
        self.assertEqual(
            quota_proxy.derive_quota_url(endpoint),
            "https://example.test:8443/v1/usage",
        )
        self.assertEqual(
            quota_proxy.local_base_url(endpoint, "127.0.0.1", 48123),
            "http://127.0.0.1:48123/backend-api/codex",
        )

    def test_account_pool_usage_is_used_when_upstream_limits_are_hidden(self):
        headers = quota_proxy.quota_headers_from_payload(
            {
                "limits": [],
                "upstream_limits": [],
                "account_pool_usage": {
                    "primary": 75.0,
                    "secondary": 80.9375,
                },
            }
        )
        self.assertEqual(headers["x-codex-primary-used-percent"], "25")
        self.assertEqual(headers["x-codex-primary-window-minutes"], "300")
        self.assertEqual(headers["x-codex-secondary-used-percent"], "19.0625")
        self.assertEqual(headers["x-codex-secondary-window-minutes"], "10080")


if __name__ == "__main__":
    unittest.main()
