#!/usr/bin/env python3
"""Client for GPU Cine Studio's opt-in local automation API (TestApiServer).

The app only opens this socket when started with GCS_TEST_API=1 (or
--test-api) - see src/core/TestApiServer.{h,cpp} and src/main.cpp. Unix
domain socket only, newline-delimited JSON, one request per line.

Usage as a library:
    from gcs_api import GcsApi
    api = GcsApi()
    api.eval("root.currentWorkspace")
    api.wait_for("root.isProjectOpen === true")

Usage as a CLI:
    python3 gcs_api.py ping
    python3 gcs_api.py eval 'root.currentWorkspace'
    python3 gcs_api.py exec 'root.loadProject("/path/to/project.gpucs"); return true;'
"""
import glob
import json
import os
import socket
import sys
import time


class GcsApiError(Exception):
    pass


def _default_socket_path():
    runtime_dir = os.environ.get("XDG_RUNTIME_DIR") or "/tmp"
    candidates = sorted(
        glob.glob(os.path.join(runtime_dir, "gpu-cine-studio-*.sock")),
        key=os.path.getmtime,
        reverse=True,
    )
    if not candidates:
        raise GcsApiError(
            f"no gpu-cine-studio-*.sock found under {runtime_dir} - "
            "is the app running with GCS_TEST_API=1?"
        )
    return candidates[0]


class GcsApi:
    def __init__(self, socket_path=None, timeout=10.0):
        self.socket_path = socket_path or _default_socket_path()
        self._sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self._sock.settimeout(timeout)
        self._sock.connect(self.socket_path)
        self._buf = b""
        self._next_id = 1

    def close(self):
        self._sock.close()

    def _recv_line(self):
        while b"\n" not in self._buf:
            chunk = self._sock.recv(65536)
            if not chunk:
                raise GcsApiError("connection closed by server")
            self._buf += chunk
        line, self._buf = self._buf.split(b"\n", 1)
        return line

    def call(self, cmd, **kwargs):
        req_id = self._next_id
        self._next_id += 1
        req = {"id": req_id, "cmd": cmd}
        req.update(kwargs)
        self._sock.sendall((json.dumps(req) + "\n").encode("utf-8"))
        line = self._recv_line()
        resp = json.loads(line.decode("utf-8"))
        if not resp.get("ok"):
            raise GcsApiError(f"{cmd} failed: {resp.get('error')}")
        return resp.get("result")

    def eval(self, expr):
        return self.call("eval", expr=expr)

    def exec(self, src):
        return self.call("exec", src=src)

    def state(self):
        return self.call("state")

    def screenshot(self, path):
        return self.call("screenshot", path=path)

    def quit(self):
        return self.call("quit")

    def wait_for(self, expr, timeout=30.0, poll=0.2):
        deadline = time.time() + timeout
        last = None
        while time.time() < deadline:
            last = self.eval(expr)
            if last:
                return last
            time.sleep(poll)
        raise GcsApiError(f"wait_for({expr!r}) timed out after {timeout}s (last value: {last!r})")


def _main(argv):
    if len(argv) < 2:
        print(__doc__)
        return 1
    cmd = argv[1]
    api = GcsApi()
    try:
        if cmd == "eval":
            result = api.eval(argv[2])
        elif cmd == "exec":
            result = api.exec(argv[2])
        elif cmd == "screenshot":
            result = api.screenshot(argv[2])
        else:
            result = api.call(cmd)
        print(json.dumps(result, indent=2))
    finally:
        api.close()
    return 0


if __name__ == "__main__":
    sys.exit(_main(sys.argv))
