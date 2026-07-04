#!/usr/bin/env python3
"""Small MiMo/OpenAI compatibility proxy.

Caddy still owns public client auth and upstream API-key injection. This local
shim only normalizes JSON request bodies before forwarding them to MiMo.
"""

from __future__ import annotations

import argparse
import http.client
import json
import os
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any
from urllib.parse import urlsplit

UNDEFINED_SENTINEL = "[undefined]"
CHAT_COMPLETIONS_PATH = "/v1/chat/completions"

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


class _DropValue:
    pass


DROP = _DropValue()


def normalize_json_for_mimo(value: Any, *, field_name: str | None = None) -> Any:
    """Remove client-side undefined sentinels while preserving prompt content."""
    if isinstance(value, dict):
        normalized: dict[str, Any] = {}
        for key, child in value.items():
            child_value = normalize_json_for_mimo(child, field_name=str(key))
            if child_value is not DROP:
                normalized[key] = child_value
        return normalized

    if isinstance(value, list):
        normalized_items = []
        for child in value:
            child_value = normalize_json_for_mimo(child, field_name=field_name)
            if child_value is not DROP:
                normalized_items.append(child_value)
        return normalized_items

    if value == UNDEFINED_SENTINEL and field_name not in {"content", "text"}:
        return DROP

    return value


def _is_chat_completion_path(path: str) -> bool:
    return urlsplit(path).path == CHAT_COMPLETIONS_PATH


def _header_value(headers: dict[str, str], name: str) -> str:
    for key, value in headers.items():
        if key.lower() == name.lower():
            return value
    return ""


def _without_header(headers: dict[str, str], name: str) -> dict[str, str]:
    return {key: value for key, value in headers.items() if key.lower() != name.lower()}


def _is_json_content_type(headers: dict[str, str]) -> bool:
    content_type = _header_value(headers, "content-type")
    return "application/json" in content_type.lower()


def normalize_request_body(path: str, headers: dict[str, str], body: bytes) -> tuple[bytes, dict[str, str]]:
    """Normalize an incoming request body and update headers for forwarding."""
    forwarded_headers = {str(key): str(value) for key, value in headers.items()}
    if not body or not _is_chat_completion_path(path) or not _is_json_content_type(forwarded_headers):
        return body, forwarded_headers

    try:
        payload = json.loads(body.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError):
        return body, forwarded_headers

    normalized_payload = normalize_json_for_mimo(payload)
    if normalized_payload is DROP:
        normalized_payload = None

    normalized_body = json.dumps(normalized_payload, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    forwarded_headers = _without_header(forwarded_headers, "content-encoding")
    forwarded_headers = _without_header(forwarded_headers, "content-length")
    forwarded_headers["Content-Length"] = str(len(normalized_body))
    return normalized_body, forwarded_headers


def _upstream_parts() -> tuple[str, int, bool]:
    upstream = os.environ.get("UPSTREAM", "")
    if not upstream or ":" not in upstream:
        raise RuntimeError("UPSTREAM must be set as host:port")

    host, port_text = upstream.rsplit(":", 1)
    port = int(port_text)
    upstream_tls = os.environ.get("UPSTREAM_TLS", "").lower()
    use_tls = upstream_tls in {"1", "true", "yes", "on"} if upstream_tls else port == 443
    return host, port, use_tls


def _filtered_request_headers(headers: dict[str, str], upstream_host: str, body_length: int) -> dict[str, str]:
    filtered: dict[str, str] = {}
    for key, value in headers.items():
        lower = key.lower()
        if lower in HOP_BY_HOP_HEADERS:
            continue
        if lower == "host":
            filtered["Host"] = value or upstream_host
        elif lower == "content-length":
            filtered["Content-Length"] = str(body_length)
        else:
            filtered[key] = value

    filtered.setdefault("Host", upstream_host)
    if body_length:
        filtered["Content-Length"] = str(body_length)
    else:
        filtered.pop("Content-Length", None)
    return filtered


def _is_streaming_response(response: http.client.HTTPResponse) -> bool:
    return "text/event-stream" in (response.getheader("Content-Type") or "").lower()


class CompatProxyHandler(BaseHTTPRequestHandler):
    server_version = "mimo-openai-compat-proxy/1.0"

    def do_GET(self) -> None:
        self._proxy()

    def do_POST(self) -> None:
        self._proxy()

    def do_PUT(self) -> None:
        self._proxy()

    def do_PATCH(self) -> None:
        self._proxy()

    def do_DELETE(self) -> None:
        self._proxy()

    def do_OPTIONS(self) -> None:
        self._proxy()

    def log_message(self, fmt: str, *args: Any) -> None:
        sys.stderr.write("%s - - [%s] %s\n" % (self.client_address[0], self.log_date_time_string(), fmt % args))

    def _proxy(self) -> None:
        try:
            self._proxy_once()
        except Exception as exc:  # noqa: BLE001 - boundary error converted to HTTP response
            print(f"proxy error: {type(exc).__name__}: {exc}", file=sys.stderr)
            body = json.dumps({"error": {"message": "Proxy upstream error", "code": "502"}}).encode("utf-8")
            self.send_response(502, "Bad Gateway")
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

    def _proxy_once(self) -> None:
        upstream_host, upstream_port, use_tls = _upstream_parts()
        content_length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(content_length) if content_length > 0 else b""
        incoming_headers = {key: value for key, value in self.headers.items()}
        body, normalized_headers = normalize_request_body(self.path, incoming_headers, body)
        request_headers = _filtered_request_headers(normalized_headers, upstream_host, len(body))

        timeout = float(os.environ.get("SHIM_UPSTREAM_TIMEOUT", "900"))
        connection_cls = http.client.HTTPSConnection if use_tls else http.client.HTTPConnection
        connection = connection_cls(upstream_host, upstream_port, timeout=timeout)
        try:
            connection.request(self.command, self.path, body=body if body else None, headers=request_headers)
            response = connection.getresponse()
            self.send_response(response.status, response.reason)
            for key, value in response.getheaders():
                lower = key.lower()
                if lower in HOP_BY_HOP_HEADERS:
                    continue
                self.send_header(key, value)
            self.end_headers()

            if _is_streaming_response(response):
                while True:
                    chunk = response.readline()
                    if not chunk:
                        break
                    self.wfile.write(chunk)
                    self.wfile.flush()
            else:
                while True:
                    chunk = response.read(65536)
                    if not chunk:
                        break
                    self.wfile.write(chunk)
                    self.wfile.flush()
        finally:
            connection.close()


def main() -> None:
    parser = argparse.ArgumentParser(description="MiMo OpenAI compatibility proxy")
    parser.add_argument("--host", default=os.environ.get("SHIM_HOST", "127.0.0.1"))
    parser.add_argument("--port", type=int, default=int(os.environ.get("SHIM_PORT", "8360")))
    args = parser.parse_args()

    _upstream_parts()
    server = ThreadingHTTPServer((args.host, args.port), CompatProxyHandler)
    print(f"OpenAI compatibility shim listening on {args.host}:{args.port}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
