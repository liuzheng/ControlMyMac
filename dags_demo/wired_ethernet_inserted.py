"""Trigger a task when a macOS USB Ethernet adapter appears.

The sensor defers to the Airflow Triggerer, so it does not occupy an executor
worker while waiting.  It defaults to the currently attached USB Ethernet
adapter, ``en12``; set ``CONTROLMYMAC_WIRED_INTERFACES`` to a comma-separated
list to watch different interfaces.
"""
from __future__ import annotations

import asyncio
import json
import logging
import os
import secrets
import subprocess
from collections.abc import Sequence
from datetime import datetime
from pathlib import Path
from typing import Any

from airflow.exceptions import AirflowException
from airflow.sdk import BaseSensorOperator, Context, DAG, task
from airflow.triggers.base import BaseTrigger, TriggerEvent

DAG_ID = "wired_ethernet_inserted"
DEFAULT_POLL_INTERVAL_SECONDS = 5.0
DEFAULT_WIRED_INTERFACES = ("en12",)
IFCONFIG = "/sbin/ifconfig"
STATE_FILENAME = "wired_ethernet_inserted-state.json"


def monitored_interfaces() -> tuple[str, ...]:
    """Return configured adapters, defaulting to the currently used USB adapter."""
    configured = os.environ.get("CONTROLMYMAC_WIRED_INTERFACES", "")
    interfaces = tuple(interface.strip() for interface in configured.split(",") if interface.strip())
    return interfaces or DEFAULT_WIRED_INTERFACES


def _run(command: Sequence[str]) -> str:
    try:
        result = subprocess.run(
            command,
            check=False,
            capture_output=True,
            text=True,
            timeout=5,
        )
    except (OSError, subprocess.TimeoutExpired):
        return ""
    return result.stdout if result.returncode == 0 else ""


def interface_is_present(interface: str) -> bool:
    """Return whether macOS currently exposes the interface, link state aside."""
    return bool(_run((IFCONFIG, interface)))


def present_interfaces() -> set[str]:
    return {interface for interface in monitored_interfaces() if interface_is_present(interface)}


def has_active_link(interface: str) -> bool:
    """Include the physical-link state as event metadata without requiring it."""
    return any(
        line.strip().casefold() == "status: active"
        for line in _run((IFCONFIG, interface)).splitlines()
    )


def trigger_state_path() -> Path:
    airflow_home = Path(os.environ.get("AIRFLOW_HOME", Path.home() / ".airflow"))
    return airflow_home / STATE_FILENAME


def read_known_interfaces(path: Path) -> set[str]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
        interfaces = value.get("present_interfaces", [])
    except (OSError, ValueError, AttributeError):
        return set()
    return {interface for interface in interfaces if isinstance(interface, str)}


def write_known_interfaces(path: Path, interfaces: set[str]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    temporary = path.with_name(f".{path.name}.{secrets.token_hex(8)}.tmp")
    try:
        temporary.write_text(
            json.dumps({"present_interfaces": sorted(interfaces)}, sort_keys=True),
            encoding="utf-8",
        )
        temporary.chmod(0o600)
        temporary.replace(path)
        path.chmod(0o600)
    finally:
        try:
            temporary.unlink()
        except FileNotFoundError:
            pass


class WiredEthernetInsertionTrigger(BaseTrigger):
    """Yield once when a monitored USB Ethernet interface newly appears.

    A small state file in ``AIRFLOW_HOME`` lets the next ``@continuous`` DAG
    run continue waiting instead of repeatedly firing for an adapter that is
    still connected.  It also makes an adapter already present when the DAG
    first starts produce one event.
    """

    def __init__(self, poll_interval_seconds: float = DEFAULT_POLL_INTERVAL_SECONDS) -> None:
        super().__init__()
        self.poll_interval_seconds = poll_interval_seconds

    def serialize(self) -> tuple[str, dict[str, Any]]:
        return (
            "wired_ethernet_inserted.WiredEthernetInsertionTrigger",
            {"poll_interval_seconds": self.poll_interval_seconds},
        )

    async def run(self):
        state_path = trigger_state_path()
        known = await asyncio.to_thread(read_known_interfaces, state_path)
        while True:
            present = await asyncio.to_thread(present_interfaces)
            inserted = sorted(present - known)
            if inserted:
                await asyncio.to_thread(write_known_interfaces, state_path, present)
                yield TriggerEvent(
                    {
                        "event": "wired_ethernet_inserted",
                        "interfaces": inserted,
                        "link_active": {
                            interface: await asyncio.to_thread(has_active_link, interface)
                            for interface in inserted
                        },
                        "detected_at": datetime.now().astimezone().isoformat(),
                    }
                )
                return
            if present != known:
                await asyncio.to_thread(write_known_interfaces, state_path, present)
                known = present
            await asyncio.sleep(self.poll_interval_seconds)


class WiredEthernetInsertedSensor(BaseSensorOperator):
    """Defer until a monitored USB Ethernet interface is inserted."""

    def __init__(self, *, poll_interval_seconds: float = DEFAULT_POLL_INTERVAL_SECONDS, **kwargs: Any) -> None:
        super().__init__(**kwargs)
        if poll_interval_seconds <= 0:
            raise AirflowException("poll_interval_seconds must be greater than zero")
        self.poll_interval_seconds = poll_interval_seconds

    def execute(self, context: Context) -> None:
        self.defer(
            trigger=WiredEthernetInsertionTrigger(self.poll_interval_seconds),
            method_name="execute_complete",
        )

    def execute_complete(self, context: Context, event: dict[str, Any] | None = None) -> dict[str, Any]:
        if not event or event.get("event") != "wired_ethernet_inserted":
            raise AirflowException(f"Unexpected wired Ethernet trigger event: {event!r}")
        return event


@task(task_id="record_insertion")
def log_wired_ethernet_insertion(event: dict[str, Any]) -> None:
    """Default event action; replace or extend this task for local automation."""
    logging.getLogger(__name__).info(
        "USB Ethernet adapter detected on %s at %s (link active: %s)",
        ", ".join(event["interfaces"]),
        event["detected_at"],
        event["link_active"],
    )


with DAG(
    dag_id=DAG_ID,
    description="Run when the monitored macOS USB Ethernet interface appears.",
    schedule="@continuous",
    start_date=datetime(2026, 1, 1),
    catchup=False,
    max_active_runs=1,
    tags=["controlmymac", "event-driven", "network"],
) as dag:
    await_wired_ethernet = WiredEthernetInsertedSensor(
        task_id="await_wired_ethernet",
        poll_interval_seconds=DEFAULT_POLL_INTERVAL_SECONDS,
    )
    record_insertion = log_wired_ethernet_insertion(await_wired_ethernet.output)
    await_wired_ethernet >> record_insertion
