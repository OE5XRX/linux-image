"""Standalone dummy OTA server that speaks the station-agent's real protocol.

This is a *test double*, not a station-manager reimplementation. It mirrors the
agent-facing endpoints (see docs/superpowers/specs/2026-07-11-boot-ota-integration-test-design.md
and station-manager apps/deployments/api_views.py) and RECORDS every interaction
so tests can assert "did the agent commit at the expected version?".

The agent authenticates with Ed25519-signed headers but never validates server
responses beyond the HTTP status code, so this server IGNORES all auth headers.
"""

from __future__ import annotations

import json
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class _Handler(BaseHTTPRequestHandler):
    # Silence the default stderr request logging.
    def log_message(self, *args):  # noqa: D401,N802
        pass

    @property
    def ctl(self) -> "DummyOtaServer":
        return self.server.ctl  # type: ignore[attr-defined]

    def _read_json(self) -> dict:
        length = int(self.headers.get("Content-Length", 0) or 0)
        if not length:
            return {}
        raw = self.rfile.read(length)
        try:
            return json.loads(raw or b"{}")
        except json.JSONDecodeError:
            return {}

    def _send_json(self, status: int, obj: dict | None) -> None:
        body = b"" if obj is None else json.dumps(obj).encode()
        self.send_response(status)
        if body:
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if body:
            self.wfile.write(body)

    # -- routing -----------------------------------------------------------
    def do_POST(self):  # noqa: N802
        ctl = self.ctl
        path = self.path
        body = self._read_json()

        if path == "/api/v1/heartbeat/":
            ctl.heartbeats.append(body)
            return self._send_json(200, {"status": "ok"})

        if path == "/api/v1/deployments/check/":
            if ctl.offer_update:
                return self._send_json(200, ctl.check_response())
            return self._send_json(204, None)

        if path == "/api/v1/deployments/commit/":
            ctl.commits.append(body)
            return self._send_json(200, {"status": "ok"})

        # POST /api/v1/deployments/<pk>/status/
        parts = path.strip("/").split("/")
        if len(parts) == 5 and parts[:3] == ["api", "v1", "deployments"] and parts[4] == "status":
            ctl.status_updates.append({"result_pk": parts[3], **body})
            return self._send_json(200, {"status": "ok"})

        return self._send_json(404, {"detail": "not found"})

    def do_GET(self):  # noqa: N802
        ctl = self.ctl
        parts = self.path.strip("/").split("/")
        # GET /api/v1/deployments/<id>/download/
        if len(parts) == 5 and parts[:3] == ["api", "v1", "deployments"] and parts[4] == "download":
            if not ctl.payload_path:
                return self._send_json(404, {"detail": "no payload configured"})
            with open(ctl.payload_path, "rb") as fh:
                data = fh.read()
            ctl.downloads += 1
            self.send_response(200)
            self.send_header("Content-Type", "application/x-bzip2")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            return
        return self._send_json(404, {"detail": "not found"})


class DummyOtaServer:
    """A recording OTA test double.

    Args:
        payload_path: path to the bz2 rootfs served on /download/ (T2), or None.
        checksum: sha256 hex of the compressed payload advertised in /check/.
        size: byte size of the compressed payload advertised in /check/.
        target_tag: the release tag advertised as the update target.
    """

    def __init__(self, payload_path, checksum, size, target_tag,
                 deployment_id=1, deployment_result_id=1):
        self.payload_path = payload_path
        self.checksum = checksum
        self.size = size
        self.target_tag = target_tag
        self.deployment_id = deployment_id
        self.deployment_result_id = deployment_result_id

        # test knobs
        self.offer_update: bool = False
        self.result_status: str = "pending"  # set to "rebooting" post-reboot

        # recorded state
        self.heartbeats: list[dict] = []
        self.status_updates: list[dict] = []
        self.commits: list[dict] = []
        self.downloads: int = 0

        self._httpd: ThreadingHTTPServer | None = None
        self._thread: threading.Thread | None = None

    # -- lifecycle ---------------------------------------------------------
    def start(self) -> None:
        self._httpd = ThreadingHTTPServer(("0.0.0.0", 0), _Handler)
        self._httpd.ctl = self  # type: ignore[attr-defined]
        self._thread = threading.Thread(target=self._httpd.serve_forever, daemon=True)
        self._thread.start()

    def stop(self) -> None:
        if self._httpd is not None:
            self._httpd.shutdown()
            self._httpd.server_close()
            self._httpd = None
        if self._thread is not None:
            self._thread.join(timeout=5)
            self._thread = None

    # -- helpers -----------------------------------------------------------
    @property
    def port(self) -> int:
        assert self._httpd is not None, "server not started"
        return self._httpd.server_address[1]

    @property
    def url(self) -> str:
        return f"http://127.0.0.1:{self.port}"

    def check_response(self) -> dict:
        return {
            "deployment_result_id": self.deployment_result_id,
            "deployment_id": self.deployment_id,
            "deployment_result_status": self.result_status,
            "target_tag": self.target_tag,
            "checksum_sha256": self.checksum or "",
            "size_bytes": self.size or 0,
            "download_url": f"/api/v1/deployments/{self.deployment_id}/download/",
        }

    def last_reported_version(self) -> str | None:
        return self.commits[-1].get("version") if self.commits else None
