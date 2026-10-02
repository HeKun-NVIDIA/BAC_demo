#!/usr/bin/env python3
"""Workshop web server.

/workspace/demos/  pages OpenClaw writes (served uncached, directory listing)
/vendor/           offline front-end libraries (Three.js)
/api/llm/...       same-origin proxy to the local Qwen API (OpenAI compatible)
/api/tts/...       same-origin proxy to the local Qwen3-TTS API
/api/services/...  loopback-only supervisor for participant Python apps
"""

from __future__ import annotations

import http.client
import json
import os
import signal
import subprocess
import time
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import unquote, urlsplit

ROOT = Path(__file__).resolve().parent
DEMO_ROOT = ROOT.parent
PORT = int(os.environ.get("SHOWCASE_PORT", "18088"))
QWEN_PORT = int(os.environ.get("QWEN_PORT", "18000"))
TTS_PORT = int(os.environ.get("TTS_PORT", "18002"))
MAX_BODY = 32 * 1024 * 1024
PIDS_DIR = DEMO_ROOT / "runtime" / "pids"
LOGS_DIR = DEMO_ROOT / "logs"
WORKSPACE_DEMOS = (DEMO_ROOT / "workspace" / "demos").resolve()
APP_PYTHON = DEMO_ROOT / "runtime" / "pyenv" / "bin" / "python"

STATIC_ROOTS = {
    "/workspace/demos/": DEMO_ROOT / "workspace" / "demos",
    "/vendor/": ROOT / "vendor",
}
PROXIES = {"/api/llm/": QWEN_PORT, "/api/tts/": TTS_PORT}


def _service_pid_file(name: str) -> Path:
    return PIDS_DIR / f"app-{name}.pid"


def _read_service_pid(name: str) -> int | None:
    try:
        return int(_service_pid_file(name).read_text().strip())
    except (OSError, ValueError):
        return None


def _pid_running(pid: int | None) -> bool:
    if not pid:
        return False
    try:
        os.kill(pid, 0)
        return True
    except OSError:
        return False


def stop_service(name: str) -> bool:
    pid_file = _service_pid_file(name)
    pid = _read_service_pid(name)
    if _pid_running(pid):
        try:
            os.killpg(pid, signal.SIGTERM)
        except OSError:
            pass
        for _ in range(20):
            if not _pid_running(pid):
                break
            time.sleep(0.1)
        if _pid_running(pid):
            try:
                os.killpg(pid, signal.SIGKILL)
            except OSError:
                pass
    pid_file.unlink(missing_ok=True)
    return bool(pid)


def start_service(name: str, relative_script: str, port: int) -> dict:
    if not name.replace("-", "").isalnum() or len(name) > 40:
        raise ValueError("invalid service name")
    if port < 18090 or port > 18099:
        raise ValueError("port must be in 18090-18099")
    script = (DEMO_ROOT / "workspace" / relative_script).resolve()
    if (
        script.suffix != ".py"
        or not script.is_file()
        or WORKSPACE_DEMOS not in script.parents
    ):
        raise ValueError("script must be an existing .py file under demos/")
    if not APP_PYTHON.is_file():
        raise ValueError("workshop Python environment is missing")

    stop_service(name)
    PIDS_DIR.mkdir(parents=True, exist_ok=True)
    LOGS_DIR.mkdir(parents=True, exist_ok=True)
    log_path = LOGS_DIR / f"app-{name}.log"
    log_handle = log_path.open("ab", buffering=0)
    env = os.environ.copy()
    env.update({"PORT": str(port), "PYTHONUNBUFFERED": "1"})
    process = subprocess.Popen(
        [str(APP_PYTHON), str(script)],
        cwd=script.parent,
        stdin=subprocess.DEVNULL,
        stdout=log_handle,
        stderr=subprocess.STDOUT,
        env=env,
        start_new_session=True,
    )
    log_handle.close()
    _service_pid_file(name).write_text(f"{process.pid}\n")
    time.sleep(0.5)
    if process.poll() is not None:
        _service_pid_file(name).unlink(missing_ok=True)
        tail = log_path.read_text("utf-8", errors="replace")[-2000:]
        raise RuntimeError(f"service exited with {process.returncode}: {tail}")
    return {
        "ok": True,
        "name": name,
        "pid": process.pid,
        "port": port,
        "script": str(script.relative_to(DEMO_ROOT / "workspace")),
        "log": str(log_path),
    }


class Handler(SimpleHTTPRequestHandler):
    server_version = "DGXSparkWorkshop/2.0"

    def log_message(self, fmt: str, *args) -> None:
        if not self.path.startswith("/api/health"):
            super().log_message(fmt, *args)

    def translate_path(self, path: str) -> str:
        url_path = unquote(urlsplit(path).path)
        for prefix, base in STATIC_ROOTS.items():
            if url_path.startswith(prefix) or url_path == prefix.rstrip("/"):
                base = base.resolve()
                candidate = (base / url_path[len(prefix):]).resolve()
                if candidate == base or base in candidate.parents:
                    return str(candidate)
        return str(ROOT / "__not_found__")

    def end_headers(self) -> None:
        if self.path.startswith(("/workspace/", "/api/")):
            self.send_header("Cache-Control", "no-store")
        super().end_headers()

    def _json(self, status: int, payload) -> None:
        body = json.dumps(payload, ensure_ascii=False).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _read_body(self) -> bytes:
        length = int(self.headers.get("Content-Length") or 0)
        if length > MAX_BODY:
            raise ValueError("request body too large")
        return self.rfile.read(length) if length else b""

    def _proxy(self, port: int, prefix: str) -> None:
        try:
            body = self._read_body() if self.command == "POST" else None
        except ValueError as exc:
            self._json(413, {"error": str(exc)})
            return
        upstream_path = "/" + self.path[len(prefix):]
        headers = {"Content-Type": self.headers.get("Content-Type", "application/json")}
        try:
            conn = http.client.HTTPConnection("127.0.0.1", port, timeout=600)
            conn.request(self.command, upstream_path, body=body, headers=headers)
            resp = conn.getresponse()
        except OSError as exc:
            self._json(502, {"error": f"local model service unavailable: {exc}"})
            return
        self.send_response(resp.status)
        for key in ("Content-Type",):
            if resp.getheader(key):
                self.send_header(key, resp.getheader(key))
        self.send_header("Connection", "close")
        self.end_headers()
        while chunk := resp.read1(65536):
            self.wfile.write(chunk)
            self.wfile.flush()
        conn.close()
        self.close_connection = True

    def _proxy_target(self):
        for prefix, port in PROXIES.items():
            if self.path.startswith(prefix):
                return prefix, port
        return None

    def _loopback_only(self) -> bool:
        if self.client_address[0] in ("127.0.0.1", "::1"):
            return True
        self._json(403, {"error": "service control is loopback-only"})
        return False

    def do_GET(self) -> None:  # noqa: N802
        if self.path in ("/", "/workspace", "/workspace/"):
            self.send_response(302)
            self.send_header("Location", "/workspace/demos/")
            self.end_headers()
            return
        if self.path.startswith("/api/health"):
            self._json(200, {"ok": True})
            return
        if self.path == "/favicon.ico":
            self.send_response(204)
            self.end_headers()
            return
        if self.path.startswith("/api/services/"):
            if not self._loopback_only():
                return
            name = self.path.removeprefix("/api/services/").split("?", 1)[0]
            pid = _read_service_pid(name)
            self._json(200, {"name": name, "pid": pid, "running": _pid_running(pid)})
            return
        if target := self._proxy_target():
            self._proxy(target[1], target[0])
            return
        super().do_GET()

    def do_POST(self) -> None:  # noqa: N802
        if target := self._proxy_target():
            self._proxy(target[1], target[0])
            return
        if self.path in ("/api/services/start", "/api/services/stop"):
            if not self._loopback_only():
                return
            try:
                payload = json.loads(self._read_body() or b"{}")
                name = str(payload.get("name") or "")
                if self.path.endswith("/start"):
                    result = start_service(
                        name,
                        str(payload.get("script") or ""),
                        int(payload.get("port") or 0),
                    )
                else:
                    result = {"ok": True, "name": name, "stopped": stop_service(name)}
                self._json(200, result)
            except (ValueError, RuntimeError, json.JSONDecodeError) as exc:
                self._json(400, {"error": str(exc)})
            return
        self._json(404, {"error": "not found"})


if __name__ == "__main__":
    server = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    print(f"workshop server: http://0.0.0.0:{PORT}", flush=True)
    server.serve_forever()
