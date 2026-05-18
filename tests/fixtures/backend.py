#!/usr/bin/env python3
import json
import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


BACKEND_ID = os.environ.get("BACKEND_ID", "backend")
HEALTH_FILE = os.environ.get("HEALTH_FILE", "")
HEALTH_STATUS = int(os.environ.get("HEALTH_STATUS", "200"))
HEALTH_BODY = os.environ.get("HEALTH_BODY", "ok")
HEALTH_HEADER_NAME = os.environ.get("HEALTH_HEADER_NAME", "")
HEALTH_HEADER_VALUE = os.environ.get("HEALTH_HEADER_VALUE", "")
STICKY_COOKIE = os.environ.get("STICKY_COOKIE", "")


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_GET(self):
        if self.path.startswith("/healthz"):
            healthy = not HEALTH_FILE or not os.path.exists(HEALTH_FILE)
            status = HEALTH_STATUS if healthy else 503
            body = HEALTH_BODY if healthy else "fail\n"
            self._send_text(status, body + "\n", "text/plain")
            return

        if self.path.startswith("/match-body-ok"):
            self._send_text(200, "READY", "text/plain")
            return
        if self.path.startswith("/match-body-fail"):
            self._send_text(200, "MAINTENANCE", "text/plain")
            return

        if self.headers.get("Upgrade", "").lower() == "websocket":
            self.send_response(101, "Switching Protocols")
            self.send_header("Connection", "Upgrade")
            self.send_header("Upgrade", "websocket")
            self.end_headers()
            return

        body = json.dumps(
            {
                "backend": BACKEND_ID,
                "path": self.path,
                "request_id": self.headers.get("X-Request-ID", ""),
                "forwarded_for": self.headers.get("X-Forwarded-For", ""),
                "host": self.headers.get("Host", ""),
            },
            sort_keys=True,
        )
        self._send_text(200, body + "\n", "application/json")

    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(length).decode("utf-8")
        self._send_text(200, f"{BACKEND_ID}:{body}\n")

    def log_message(self, fmt, *args):
        return

    def _send_text(self, status, body, content_type="text/plain"):
        encoded = body.encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(encoded)))
        if STICKY_COOKIE:
            self.send_header("Set-Cookie", STICKY_COOKIE)
        self.end_headers()
        self.wfile.write(encoded)


if __name__ == "__main__":
    port = int(os.environ["PORT"])
    ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()
