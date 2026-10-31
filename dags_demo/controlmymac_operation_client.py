"""Standard-library client for the phase-one ControlMyMac app-hosted socket."""
from __future__ import annotations

import json
import os
import socket
import struct
from pathlib import Path
from typing import Any

PROTOCOL_VERSION = 1
MAX_FRAME_BYTES = 64 * 1024
SOCKET_PATH = Path(os.environ.get(
    "CONTROLMYMAC_OPERATION_SOCKET",
    Path.home() / "Library/Application Support/ControlMyMac/authorization/broker.sock",
))


class ControlMyMacOperationError(RuntimeError):
    pass


def _exchange(request: dict[str, Any], timeout_seconds: float = 5) -> dict[str, Any]:
    payload = json.dumps(request, separators=(",", ":")).encode("utf-8")
    if len(payload) > MAX_FRAME_BYTES:
        raise ControlMyMacOperationError("request exceeds ControlMyMac socket frame limit")
    frame = struct.pack(">I", len(payload)) + payload
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
            client.settimeout(timeout_seconds)
            client.connect(str(SOCKET_PATH))
            client.sendall(frame)
            header = _read_exactly(client, 4)
            length = struct.unpack(">I", header)[0]
            if length > MAX_FRAME_BYTES:
                raise ControlMyMacOperationError("ControlMyMac returned an oversized response")
            response = json.loads(_read_exactly(client, length))
    except (OSError, TimeoutError) as error:
        raise ControlMyMacOperationError(
            "ControlMyMac app is not running or its local operation socket is unavailable"
        ) from error
    if response.get("errorCode"):
        raise ControlMyMacOperationError(f"ControlMyMac rejected request: {response['errorCode']}")
    return response


def _read_exactly(client: socket.socket, count: int) -> bytes:
    chunks: list[bytes] = []
    remaining = count
    while remaining:
        chunk = client.recv(remaining)
        if not chunk:
            raise ControlMyMacOperationError("ControlMyMac closed the socket before responding")
        chunks.append(chunk)
        remaining -= len(chunk)
    return b"".join(chunks)


def create_configure_en9(*, mac_address: str, search_domain: str, title: str, description: str) -> dict[str, Any]:
    return _exchange({
        "protocolVersion": PROTOCOL_VERSION,
        "action": "create",
        "payload": {
            "operationID": "configure_en9",
            "registryVersion": 1,
            "parameters": {
                "type": "configureEN9",
                "value": {"interface": "en9", "macAddress": mac_address, "searchDomain": search_domain},
            },
            "approval": {"title": title, "description": description},
        },
    })


def status(request_id: str) -> dict[str, Any]:
    return _exchange({"protocolVersion": PROTOCOL_VERSION, "action": "status", "requestID": {"value": request_id}})


def cancel(request_id: str) -> dict[str, Any]:
    return _exchange({"protocolVersion": PROTOCOL_VERSION, "action": "cancel", "requestID": {"value": request_id}})
