#!/usr/bin/env python3
"""Standard-library tests for the phase-one DAG socket client."""
from __future__ import annotations

import importlib.util
import json
import socket
import struct
import tempfile
import threading
import unittest
from pathlib import Path

CLIENT_PATH = Path(__file__).parents[1] / "dags_demo" / "controlmymac_operation_client.py"


def load_client():
    spec = importlib.util.spec_from_file_location("controlmymac_operation_client_test", CLIENT_PATH)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class SocketServer:
    def __init__(self, path: Path, response: dict[str, object]) -> None:
        self.path = path
        self.response = response
        self.request: dict[str, object] | None = None
        self.ready = threading.Event()
        self.thread = threading.Thread(target=self.run, daemon=True)

    def start(self) -> None:
        self.thread.start()
        self.ready.wait(timeout=2)

    def join(self) -> None:
        self.thread.join(timeout=2)

    def run(self) -> None:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as server:
            server.bind(str(self.path))
            server.listen(1)
            self.ready.set()
            client, _ = server.accept()
            with client:
                header = client.recv(4)
                length = struct.unpack(">I", header)[0]
                payload = client.recv(length)
                self.request = json.loads(payload)
                body = json.dumps(self.response, separators=(",", ":")).encode()
                client.sendall(struct.pack(">I", len(body)) + body)


class ControlMyMacOperationClientTests(unittest.TestCase):
    def test_create_configure_en9_sends_only_registered_shape(self) -> None:
        client = load_client()
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "broker.sock"
            server = SocketServer(path, {"requestID": {"value": "request-id"}, "state": "pending_authorization"})
            server.start()
            client.SOCKET_PATH = path
            response = client.create_configure_en9(
                mac_address="7c:8a:e1:8d:ab:2f",
                search_domain="cn1.global.ctrip.com",
                title="配置网络",
                description="手动执行",
            )
            server.join()

        self.assertEqual(response["state"], "pending_authorization")
        assert server.request is not None
        self.assertEqual(server.request["action"], "create")
        payload = server.request["payload"]
        self.assertEqual(payload["operationID"], "configure_en9")
        self.assertEqual(payload["parameters"]["value"]["interface"], "en9")
        self.assertNotIn("command", payload)
        self.assertNotIn("argv", payload)

    def test_status_accepts_manual_execution_required(self) -> None:
        client = load_client()
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "broker.sock"
            server = SocketServer(path, {"requestID": {"value": "request-id"}, "state": "manual_execution_required"})
            server.start()
            client.SOCKET_PATH = path
            response = client.status("request-id")
            server.join()

        self.assertEqual(response["state"], "manual_execution_required")
        assert server.request is not None
        self.assertEqual(server.request["action"], "status")
        self.assertEqual(server.request["requestID"]["value"], "request-id")


if __name__ == "__main__":
    unittest.main()
