"""
Claude Proxy

Lightweight HTTP proxy that routes Anthropic API requests to alternative
providers (Moonshot, MiniMax) with automatic failover on 429/5xx errors.
Streams SSE responses transparently.
"""

import json
import logging
import os
import sys
from datetime import datetime
from http.server import HTTPServer, BaseHTTPRequestHandler
from pathlib import Path
from urllib.parse import urlparse

import urllib.request
import urllib.error

CONFIG_DIR = Path(__file__).resolve().parent
CONFIG_PATH = CONFIG_DIR / "config.json"
ENV_PATH = CONFIG_DIR / ".env"
LOG_PATH = CONFIG_DIR / "proxy.log"

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    handlers=[
        logging.FileHandler(LOG_PATH, encoding="utf-8"),
        logging.StreamHandler(sys.stdout),
    ],
)
log = logging.getLogger("claude-proxy")


def load_env(path: Path) -> None:
    """Load .env file into os.environ (simple key=value parsing)."""
    log.info("Loading .env from: %s (exists: %s)", path, path.exists())
    if not path.exists():
        log.warning(".env file not found at %s", path)
        return
    with open(path, encoding="utf-8-sig") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            if "=" in line:
                key, _, value = line.partition("=")
                key = key.strip()
                value = value.strip()
                os.environ[key] = value
                log.info("Loaded env var: %s", key)


def load_config() -> dict:
    with open(CONFIG_PATH, encoding="utf-8") as f:
        return json.load(f)


load_env(ENV_PATH)
CONFIG = load_config()
PROVIDERS = CONFIG["providers"]

# Filter to preferred providers if specified
if os.environ.get("CLAUDE_PROVIDERS"):
    preferred = [p.strip() for p in os.environ["CLAUDE_PROVIDERS"].split(",")]
    PROVIDERS = [p for p in PROVIDERS if p["name"] in preferred]

PROXY_PORT = CONFIG.get("proxy_port", 8787)
MAX_BODY_SIZE = 10 * 1024 * 1024  # 10MB limit to prevent memory exhaustion


class ProxyHandler(BaseHTTPRequestHandler):
    """Handles incoming requests and forwards them to providers with failover."""

    # Suppress default request logging (we log ourselves)
    def log_message(self, format, *args):
        pass

    def do_GET(self):
        """Handle GET requests (health check)."""
        if self.path == "/health":
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps({"status": "ok", "providers": [p["name"] for p in PROVIDERS]}).encode())
            return
        self._proxy_request()

    def do_POST(self):
        """Handle POST requests (main API calls)."""
        self._proxy_request()

    def _proxy_request(self):
        # Read request body with size limit
        content_length = int(self.headers.get("Content-Length", 0))
        if content_length > MAX_BODY_SIZE:
            self.send_response(413)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps({
                "type": "error",
                "error": {"type": "request_too_large", "message": "Request body exceeds 10MB limit"}
            }).encode())
            return

        body = self.rfile.read(content_length) if content_length > 0 else b""

        # Determine if client wants streaming
        is_streaming = False
        if body:
            try:
                req_json = json.loads(body)
                is_streaming = req_json.get("stream", False)
            except (json.JSONDecodeError, UnicodeDecodeError):
                pass

        last_error = None

        for provider in PROVIDERS:
            api_key = os.environ.get(provider["api_key_env"], "")
            if not api_key:
                log.warning("No API key for %s (env: %s), skipping", provider["name"], provider["api_key_env"])
                continue

            target_url = provider["base_url"].rstrip("/") + self.path
            log.info("Trying %s: %s %s", provider["name"], self.command, target_url)

            # Build headers - forward everything except host and authorization
            fwd_headers = {}
            for key, value in self.headers.items():
                lower = key.lower()
                if lower in ("host", "authorization"):
                    continue
                fwd_headers[key] = value

            fwd_headers["Authorization"] = f"Bearer {api_key}"
            fwd_headers["Host"] = urlparse(provider["base_url"]).netloc

            try:
                req = urllib.request.Request(
                    target_url,
                    data=body if body else None,
                    headers=fwd_headers,
                    method=self.command,
                )

                resp = urllib.request.urlopen(req, timeout=300)
                status = resp.status
                resp_headers = dict(resp.getheaders())

            except urllib.error.HTTPError as e:
                status = e.code
                if status in (429, 500, 502, 503, 504):
                    error_body = e.read().decode("utf-8", errors="replace")[:500]
                    log.warning(
                        "%s returned %d: %s — trying next provider",
                        provider["name"], status, error_body,
                    )
                    last_error = (status, error_body)
                    continue
                else:
                    # Non-retriable error — forward it to the client as-is
                    log.info("%s returned %d (non-retriable), forwarding to client", provider["name"], status)
                    self.send_response(status)
                    for hdr_key, hdr_val in e.headers.items():
                        if hdr_key.lower() not in ("transfer-encoding", "connection"):
                            self.send_header(hdr_key, hdr_val)
                    self.end_headers()
                    self.wfile.write(e.read())
                    return

            except Exception as e:
                log.warning("%s connection error: %s — trying next provider", provider["name"], e)
                last_error = (502, str(e))
                continue

            # Success — stream the response back to the client
            log.info("%s responded %d — streaming to client", provider["name"], status)
            self.send_response(status)
            for hdr_key, hdr_val in resp_headers.items():
                if hdr_key.lower() in ("transfer-encoding", "connection"):
                    continue
                self.send_header(hdr_key, hdr_val)
            self.end_headers()

            # Stream chunks
            try:
                while True:
                    chunk = resp.read(4096)
                    if not chunk:
                        break
                    self.wfile.write(chunk)
                    self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError):
                log.info("Client disconnected during streaming")
            finally:
                resp.close()
            return

        # All providers failed
        log.error("All providers failed")
        error_status = last_error[0] if last_error else 502
        error_msg = last_error[1] if last_error else "All providers unavailable"
        self.send_response(error_status)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(json.dumps({
            "type": "error",
            "error": {
                "type": "overloaded_error",
                "message": f"All fallback providers failed. Last error: {error_msg}",
            },
        }).encode())


def main():
    active_providers = [p["name"] for p in PROVIDERS]
    log.info("Fallback proxy listening on http://127.0.0.1:%d", PROXY_PORT)
    log.info("Providers: %s", ", ".join(active_providers))
    server = HTTPServer(("127.0.0.1", PROXY_PORT), ProxyHandler)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        log.info("Proxy shutting down")
        server.shutdown()


if __name__ == "__main__":
    main()
