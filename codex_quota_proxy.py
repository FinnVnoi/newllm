#!/usr/bin/env python3
"""Local Codex pass-through proxy that adds API-key quota response headers.

The proxy binds only to loopback, forwards requests to CODEX_UPSTREAM_BASE_URL,
reads quota from CODEX_QUOTA_URL, and exposes the quota through the native
x-codex-* response headers understood by Codex CLI and Codex App.
"""

from __future__ import annotations

import argparse
import hashlib
import hmac
import http.client
import json
import os
import socket
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any, Dict, Iterable, List, Mapping, Optional, Tuple


PROXY_MARKER = "codex-quota-proxy"
HEALTH_PATH = "/__codex_quota_proxy/health"
STOP_PATH = "/__codex_quota_proxy/stop"
DEFAULT_HOST = "127.0.0.1"
DEFAULT_PORT = 48123
DEFAULT_REFRESH_SECONDS = 15.0
DEFAULT_QUOTA_TIMEOUT_SECONDS = 5.0
UPSTREAM_TIMEOUT_SECONDS = 600.0
HOP_BY_HOP_HEADERS = {
    "connection",
    "keep-alive",
    "proxy-authenticate",
    "proxy-authorization",
    "te",
    "trailer",
    "transfer-encoding",
    "upgrade",
}
MANAGED_RATE_LIMIT_PREFIXES = (
    "x-codex-primary-",
    "x-codex-secondary-",
    "x-codex-credits-",
)


class ProxyConfigurationError(RuntimeError):
    pass


@dataclass(frozen=True)
class Settings:
    host: str
    port: int
    upstream_base_url: str
    quota_url: str
    api_key: str
    local_token: str
    refresh_seconds: float

    @classmethod
    def from_environment(
        cls, require_remote: bool = True, require_token: bool = True
    ) -> "Settings":
        host = os.environ.get("CODEX_QUOTA_PROXY_HOST", DEFAULT_HOST).strip() or DEFAULT_HOST
        if host not in {"127.0.0.1", "localhost", "::1"}:
            raise ProxyConfigurationError("CODEX_QUOTA_PROXY_HOST must be a loopback address.")

        raw_port = os.environ.get("CODEX_QUOTA_PROXY_PORT", str(DEFAULT_PORT)).strip()
        try:
            port = int(raw_port)
        except ValueError as exc:
            raise ProxyConfigurationError("CODEX_QUOTA_PROXY_PORT must be an integer.") from exc
        if port < 1024 or port > 65535:
            raise ProxyConfigurationError("CODEX_QUOTA_PROXY_PORT must be between 1024 and 65535.")

        upstream_base_url = os.environ.get("CODEX_UPSTREAM_BASE_URL", "").strip().rstrip("/")
        quota_url = os.environ.get("CODEX_QUOTA_URL", "").strip()
        api_key = os.environ.get("CODEX_API_KEY", "").strip()
        local_token = os.environ.get("CODEX_QUOTA_PROXY_TOKEN", "").strip()

        if require_remote:
            _validate_remote_url(upstream_base_url, "CODEX_UPSTREAM_BASE_URL")
            _validate_remote_url(quota_url, "CODEX_QUOTA_URL")
            if not api_key:
                raise ProxyConfigurationError("CODEX_API_KEY is empty.")
        if require_token and not local_token:
            raise ProxyConfigurationError("CODEX_QUOTA_PROXY_TOKEN is empty.")

        raw_refresh = os.environ.get(
            "CODEX_QUOTA_REFRESH_SECONDS", str(DEFAULT_REFRESH_SECONDS)
        ).strip()
        try:
            refresh_seconds = max(5.0, float(raw_refresh))
        except ValueError as exc:
            raise ProxyConfigurationError(
                "CODEX_QUOTA_REFRESH_SECONDS must be a number."
            ) from exc

        return cls(
            host=host,
            port=port,
            upstream_base_url=upstream_base_url,
            quota_url=quota_url,
            api_key=api_key,
            local_token=local_token,
            refresh_seconds=refresh_seconds,
        )

    @property
    def local_base_url(self) -> str:
        upstream = urllib.parse.urlsplit(self.upstream_base_url)
        return f"http://{self.host}:{self.port}{upstream.path.rstrip('/')}"

    @property
    def fingerprint(self) -> str:
        value = "\0".join(
            (self.upstream_base_url, self.quota_url, self.api_key, self.local_token)
        ).encode("utf-8")
        return hashlib.sha256(value).hexdigest()


def _validate_remote_url(value: str, label: str) -> None:
    parsed = urllib.parse.urlsplit(value)
    if parsed.scheme not in {"http", "https"} or not parsed.netloc:
        raise ProxyConfigurationError(f"{label} must be an absolute HTTP or HTTPS URL.")
    if parsed.query or parsed.fragment:
        raise ProxyConfigurationError(f"{label} must not contain a query or fragment.")


def _as_number(value: Any) -> Optional[float]:
    if isinstance(value, bool):
        return None
    if isinstance(value, (int, float)):
        number = float(value)
        if number == number and number not in {float("inf"), float("-inf")}:
            return number
    return None


def _format_number(value: float) -> str:
    return f"{value:.6f}".rstrip("0").rstrip(".")


def _window_minutes(window: str) -> Optional[int]:
    return {
        "5h": 5 * 60,
        "daily": 24 * 60,
        "7d": 7 * 24 * 60,
        "weekly": 7 * 24 * 60,
        "monthly": 30 * 24 * 60,
        "annual": 365 * 24 * 60,
        "yearly": 365 * 24 * 60,
    }.get(window.lower())


def _reset_epoch(value: Any) -> Optional[int]:
    if not isinstance(value, str) or not value.strip():
        return None
    normalized = value.strip()
    try:
        parsed = datetime.fromisoformat(normalized.replace("Z", "+00:00"))
    except ValueError:
        return None
    if parsed.year >= 9990:
        return None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return int(parsed.timestamp())


def _limit_used_percent(limit: Mapping[str, Any]) -> Optional[float]:
    maximum = _as_number(limit.get("max_value"))
    current = _as_number(limit.get("current_value"))
    if maximum is None or current is None or maximum <= 0:
        return None
    return max(0.0, min(100.0, current * 100.0 / maximum))


def _limit_identity(limit: Mapping[str, Any]) -> Tuple[Any, ...]:
    return (
        limit.get("limit_type"),
        limit.get("limit_window"),
        limit.get("max_value"),
        limit.get("current_value"),
        limit.get("model_filter"),
        limit.get("source"),
    )


def _choose_limit(
    limits: Iterable[Mapping[str, Any]], preferred_windows: Iterable[str]
) -> Optional[Mapping[str, Any]]:
    candidates = [
        item
        for item in limits
        if item.get("model_filter") in {None, ""}
        and _limit_used_percent(item) is not None
    ]
    for window in preferred_windows:
        for item in candidates:
            if str(item.get("limit_window", "")).lower() == window:
                return item
    return candidates[0] if candidates else None


def _header_window(
    prefix: str, limit: Optional[Mapping[str, Any]]
) -> Dict[str, str]:
    if limit is None:
        return {}
    used_percent = _limit_used_percent(limit)
    if used_percent is None:
        return {}

    headers = {f"x-codex-{prefix}-used-percent": _format_number(used_percent)}
    window_name = str(limit.get("limit_window", "")).lower()
    minutes = _window_minutes(window_name)
    if minutes is not None:
        headers[f"x-codex-{prefix}-window-minutes"] = str(minutes)
    reset_at = _reset_epoch(limit.get("reset_at"))
    if reset_at is not None:
        headers[f"x-codex-{prefix}-reset-at"] = str(reset_at)
    return headers


def _pool_limit(remaining_percent: Any, window: str) -> Optional[Mapping[str, Any]]:
    remaining = _as_number(remaining_percent)
    if remaining is None:
        return None
    remaining = max(0.0, min(100.0, remaining))
    return {
        "limit_type": "account_pool",
        "limit_window": window,
        "max_value": 100.0,
        "current_value": 100.0 - remaining,
        "remaining_value": remaining,
        "model_filter": None,
        "reset_at": None,
        "source": "account_pool_usage",
    }


def quota_headers_from_payload(payload: Mapping[str, Any]) -> Dict[str, str]:
    raw_limits = payload.get("limits")
    raw_upstream = payload.get("upstream_limits")
    limits = [item for item in raw_limits if isinstance(item, dict)] if isinstance(raw_limits, list) else []
    upstream = (
        [item for item in raw_upstream if isinstance(item, dict)]
        if isinstance(raw_upstream, list)
        else []
    )
    raw_pool = payload.get("account_pool_usage")
    pool_primary = None
    pool_secondary = None
    if isinstance(raw_pool, dict):
        pool_primary = _pool_limit(raw_pool.get("primary"), "5h")
        pool_secondary = _pool_limit(raw_pool.get("secondary"), "7d")

    upstream_identities = {_limit_identity(item) for item in upstream}
    own_limits = [
        item
        for item in limits
        if str(item.get("source", "")).lower() != "aggregate"
        and _limit_identity(item) not in upstream_identities
    ]

    if own_limits:
        primary = _choose_limit(
            own_limits,
            ("lifetime", "monthly", "weekly", "7d", "daily", "5h"),
        )
        remaining_own = [item for item in own_limits if item is not primary]
        secondary = _choose_limit(remaining_own, ("7d", "weekly", "monthly"))
        if secondary is None:
            secondary = _choose_limit(upstream, ("7d", "weekly", "monthly"))
        if secondary is None:
            secondary = pool_secondary
    else:
        primary = _choose_limit(
            upstream or limits, ("5h", "daily", "lifetime", "monthly")
        )
        if primary is None:
            primary = pool_primary
        secondary_candidates = [
            item for item in (upstream or limits) if item is not primary
        ]
        secondary = _choose_limit(
            secondary_candidates, ("7d", "weekly", "monthly")
        )
        if secondary is None:
            secondary = pool_secondary

    headers: Dict[str, str] = {}
    headers.update(_header_window("primary", primary))
    headers.update(_header_window("secondary", secondary))
    return headers


class QuotaCache:
    def __init__(self, settings: Settings) -> None:
        self._settings = settings
        self._lock = threading.Lock()
        self._headers: Dict[str, str] = {}
        self._last_error: Optional[str] = None
        self._updated_at = 0.0

    def snapshot(self) -> Tuple[Dict[str, str], Optional[str], float]:
        with self._lock:
            return dict(self._headers), self._last_error, self._updated_at

    def refresh(self) -> None:
        request = urllib.request.Request(
            self._settings.quota_url,
            headers={
                "Authorization": f"Bearer {self._settings.api_key}",
                "Accept": "application/json",
                "User-Agent": f"{PROXY_MARKER}/1",
            },
            method="GET",
        )
        try:
            with urllib.request.urlopen(
                request, timeout=DEFAULT_QUOTA_TIMEOUT_SECONDS
            ) as response:
                payload = json.load(response)
            if not isinstance(payload, dict):
                raise ValueError("quota response is not a JSON object")
            headers = quota_headers_from_payload(payload)
            if not headers:
                raise ValueError("quota response does not contain a usable limit")
        except Exception as exc:
            with self._lock:
                self._last_error = f"{type(exc).__name__}: {exc}"
            return

        with self._lock:
            self._headers = headers
            self._last_error = None
            self._updated_at = time.time()

    def run(self, stop_event: threading.Event) -> None:
        while not stop_event.wait(self._settings.refresh_seconds):
            self.refresh()


class CodexQuotaProxyServer(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def __init__(self, settings: Settings) -> None:
        super().__init__((settings.host, settings.port), CodexQuotaProxyHandler)
        self.settings = settings
        self.quota_cache = QuotaCache(settings)
        self.stop_event = threading.Event()


class CodexQuotaProxyHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "CodexQuotaProxy/1"
    sys_version = ""

    @property
    def proxy_server(self) -> CodexQuotaProxyServer:
        return self.server  # type: ignore[return-value]

    def log_message(self, format_string: str, *args: Any) -> None:
        if os.environ.get("CODEX_QUOTA_PROXY_DEBUG") == "1":
            super().log_message(format_string, *args)

    def do_GET(self) -> None:
        if not self._authorize():
            return
        if self.path == HEALTH_PATH:
            self._health()
            return
        self._forward()

    def do_HEAD(self) -> None:
        if not self._authorize():
            return
        self._forward()

    def do_POST(self) -> None:
        if not self._authorize():
            return
        if self.path == STOP_PATH:
            self._stop()
            return
        self._forward()

    def do_PUT(self) -> None:
        if not self._authorize():
            return
        self._forward()

    def do_PATCH(self) -> None:
        if not self._authorize():
            return
        self._forward()

    def do_DELETE(self) -> None:
        if not self._authorize():
            return
        self._forward()

    def do_OPTIONS(self) -> None:
        if not self._authorize():
            return
        self._forward()

    def _authorize(self) -> bool:
        supplied = self.headers.get("Authorization", "")
        expected = f"Bearer {self.proxy_server.settings.local_token}"
        if hmac.compare_digest(supplied, expected):
            return True
        self._json_response(
            401,
            {
                "error": {
                    "type": "invalid_api_key",
                    "message": "Invalid local quota proxy token.",
                }
            },
        )
        return False

    def _health(self) -> None:
        headers, last_error, updated_at = self.proxy_server.quota_cache.snapshot()
        payload = {
            "service": PROXY_MARKER,
            "config_fingerprint": self.proxy_server.settings.fingerprint,
            "upstream_base_url": self.proxy_server.settings.upstream_base_url,
            "quota_url": self.proxy_server.settings.quota_url,
            "quota_loaded": bool(headers),
            "quota_updated_at": updated_at or None,
            "quota_error": last_error,
        }
        self._json_response(200, payload)

    def _stop(self) -> None:
        self._json_response(200, {"service": PROXY_MARKER, "stopping": True})
        threading.Thread(target=self.proxy_server.shutdown, daemon=True).start()

    def _json_response(self, status: int, payload: Mapping[str, Any]) -> None:
        body = json.dumps(payload, separators=(",", ":")).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)
        self.close_connection = True

    def _read_request_body(self) -> Optional[bytes]:
        raw_length = self.headers.get("Content-Length")
        if raw_length:
            try:
                length = int(raw_length)
            except ValueError as exc:
                raise ValueError("invalid Content-Length") from exc
            return self.rfile.read(length)
        if self.headers.get("Transfer-Encoding", "").lower() == "chunked":
            chunks: List[bytes] = []
            while True:
                raw_size = self.rfile.readline().split(b";", 1)[0].strip()
                size = int(raw_size, 16)
                if size == 0:
                    while self.rfile.readline() not in {b"\r\n", b"\n", b""}:
                        pass
                    break
                chunks.append(self.rfile.read(size))
                self.rfile.read(2)
            return b"".join(chunks)
        return None

    def _forward(self) -> None:
        settings = self.proxy_server.settings
        upstream = urllib.parse.urlsplit(settings.upstream_base_url)
        incoming = urllib.parse.urlsplit(self.path)
        target = urllib.parse.urlunsplit(
            ("", "", incoming.path or "/", incoming.query, "")
        )

        connection_headers = {
            token.strip().lower()
            for token in self.headers.get("Connection", "").split(",")
            if token.strip()
        }
        request_headers: Dict[str, str] = {}
        for name, value in self.headers.items():
            lowered = name.lower()
            if (
                lowered in HOP_BY_HOP_HEADERS
                or lowered in connection_headers
                or lowered in {"host", "content-length"}
            ):
                continue
            request_headers[name] = value
        request_headers["Authorization"] = f"Bearer {settings.api_key}"

        connection_class = (
            http.client.HTTPSConnection
            if upstream.scheme == "https"
            else http.client.HTTPConnection
        )
        connection = connection_class(upstream.hostname, upstream.port, timeout=UPSTREAM_TIMEOUT_SECONDS)

        try:
            body = self._read_request_body()
            if body is not None:
                request_headers["Content-Length"] = str(len(body))
            connection.request(
                self.command,
                target,
                body=body,
                headers=request_headers,
            )
            response = connection.getresponse()
        except Exception as exc:
            connection.close()
            self._json_response(
                502,
                {
                    "error": {
                        "type": "proxy_error",
                        "message": f"Unable to reach configured Codex endpoint: {exc}",
                    }
                },
            )
            return

        quota_headers, _, _ = self.proxy_server.quota_cache.snapshot()
        upstream_connection_tokens = {
            token.strip().lower()
            for name, value in response.getheaders()
            if name.lower() == "connection"
            for token in value.split(",")
            if token.strip()
        }

        self.send_response(response.status, response.reason)
        has_content_length = False
        for name, value in response.getheaders():
            lowered = name.lower()
            if lowered == "content-length":
                has_content_length = True
            if lowered in HOP_BY_HOP_HEADERS or lowered in upstream_connection_tokens:
                continue
            if quota_headers and lowered.startswith(MANAGED_RATE_LIMIT_PREFIXES):
                continue
            self.send_header(name, value)
        for name, value in quota_headers.items():
            self.send_header(name, value)
        if not has_content_length:
            self.send_header("Connection", "close")
            self.close_connection = True
        self.end_headers()

        if self.command != "HEAD":
            try:
                while True:
                    chunk = response.read1(64 * 1024)
                    if not chunk:
                        break
                    self.wfile.write(chunk)
                    self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError):
                pass
            finally:
                response.close()
                connection.close()
        else:
            response.close()
            connection.close()


def _health_url(settings: Settings) -> str:
    return f"http://{settings.host}:{settings.port}{HEALTH_PATH}"


def _stop_url(settings: Settings) -> str:
    return f"http://{settings.host}:{settings.port}{STOP_PATH}"


def _read_health(settings: Settings) -> Optional[Mapping[str, Any]]:
    try:
        request = urllib.request.Request(
            _health_url(settings),
            headers={"Authorization": f"Bearer {settings.local_token}"},
        )
        with urllib.request.urlopen(request, timeout=1.0) as response:
            payload = json.load(response)
        return payload if isinstance(payload, dict) else None
    except Exception:
        return None


def _is_matching_proxy(settings: Settings) -> bool:
    payload = _read_health(settings)
    return bool(
        payload
        and payload.get("service") == PROXY_MARKER
        and payload.get("config_fingerprint") == settings.fingerprint
        and payload.get("upstream_base_url") == settings.upstream_base_url
        and payload.get("quota_url") == settings.quota_url
    )


def ensure_running(settings: Settings) -> int:
    if _is_matching_proxy(settings):
        return 0
    occupied = _read_health(settings)
    if occupied is not None and occupied.get("service") == PROXY_MARKER:
        stop_proxy(settings)
        deadline = time.time() + 5.0
        while time.time() < deadline and _read_health(settings) is not None:
            time.sleep(0.1)
    elif occupied is not None:
        raise RuntimeError(
            f"Port {settings.port} is already used by a different quota proxy configuration."
        )

    command = [sys.executable, os.path.abspath(__file__)]
    kwargs: Dict[str, Any] = {
        "stdin": subprocess.DEVNULL,
        "stdout": subprocess.DEVNULL,
        "stderr": subprocess.DEVNULL,
        "close_fds": True,
    }
    if os.name == "nt":
        kwargs["creationflags"] = (
            getattr(subprocess, "CREATE_NO_WINDOW", 0)
            | getattr(subprocess, "DETACHED_PROCESS", 0)
            | getattr(subprocess, "CREATE_NEW_PROCESS_GROUP", 0)
        )
    else:
        kwargs["start_new_session"] = True
    subprocess.Popen(command, **kwargs)

    deadline = time.time() + 8.0
    while time.time() < deadline:
        if _is_matching_proxy(settings):
            return 0
        time.sleep(0.1)
    raise RuntimeError("Quota proxy did not become ready.")


def stop_proxy(settings: Settings) -> int:
    request = urllib.request.Request(
        _stop_url(settings),
        data=b"",
        headers={"Authorization": f"Bearer {settings.local_token}"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=2.0):
            pass
    except (urllib.error.URLError, TimeoutError):
        return 0
    deadline = time.time() + 5.0
    while time.time() < deadline:
        if _read_health(settings) is None:
            return 0
        time.sleep(0.1)
    return 1


def find_available_port(host: str, preferred_port: int) -> int:
    for port in range(preferred_port, min(preferred_port + 50, 65536)):
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as candidate:
            try:
                candidate.bind((host, port))
            except OSError:
                continue
            return port
    raise RuntimeError("No free quota proxy port was found.")


def derive_quota_url(endpoint: str) -> str:
    _validate_remote_url(endpoint, "endpoint")
    parsed = urllib.parse.urlsplit(endpoint)
    return urllib.parse.urlunsplit(
        (parsed.scheme, parsed.netloc, "/v1/usage", "", "")
    )


def local_base_url(endpoint: str, host: str, port: int) -> str:
    _validate_remote_url(endpoint, "endpoint")
    parsed = urllib.parse.urlsplit(endpoint)
    return urllib.parse.urlunsplit(
        ("http", f"{host}:{port}", parsed.path.rstrip("/"), "", "")
    )


def run_server(settings: Settings) -> int:
    server = CodexQuotaProxyServer(settings)
    server.quota_cache.refresh()
    refresh_thread = threading.Thread(
        target=server.quota_cache.run,
        args=(server.stop_event,),
        name="codex-quota-refresh",
        daemon=True,
    )
    refresh_thread.start()
    try:
        server.serve_forever(poll_interval=0.5)
    finally:
        server.stop_event.set()
        server.server_close()
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ensure-running", action="store_true")
    parser.add_argument("--stop", action="store_true")
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--find-port", action="store_true")
    parser.add_argument("--derive-quota-url", metavar="ENDPOINT")
    parser.add_argument("--local-base-url", metavar="ENDPOINT")
    args = parser.parse_args()

    try:
        if args.derive_quota_url:
            print(derive_quota_url(args.derive_quota_url))
            return 0

        if args.local_base_url:
            settings = Settings.from_environment(
                require_remote=False, require_token=False
            )
            print(local_base_url(args.local_base_url, settings.host, settings.port))
            return 0

        if args.find_port:
            settings = Settings.from_environment(
                require_remote=False, require_token=False
            )
            print(find_available_port(settings.host, settings.port))
            return 0

        settings = Settings.from_environment(require_remote=not args.stop)
        if args.ensure_running:
            return ensure_running(settings)
        if args.stop:
            return stop_proxy(settings)
        if args.check:
            payload = _read_health(settings)
            if payload is None:
                return 1
            print(json.dumps(payload, indent=2, sort_keys=True))
            return 0
        return run_server(settings)
    except (ProxyConfigurationError, RuntimeError, OSError) as exc:
        print(f"Error: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
