"""Trigger a task when the configured Feishu application receives a message.

The listener task declares its own ``lark-oapi`` requirement through Airflow's
``@task.virtualenv`` decorator. It uses an Airflow Connection for its Feishu
credentials, so neither application secrets nor allow-lists live in the DAG
source or a shell environment.

Only message metadata reaches the downstream task; message bodies and app
credentials are intentionally neither returned nor logged by this demo.
"""
from __future__ import annotations

import logging
from datetime import datetime
from typing import Any

from airflow.sdk import DAG, task

DAG_ID = "feishu_message_received"
FEISHU_CONNECTION_ID = "feishu_message_listener"
FEISHU_SDK_REQUIREMENT = "lark-oapi==1.6.4"


@task.virtualenv(
    task_id="await_feishu_message",
    requirements=[FEISHU_SDK_REQUIREMENT],
    system_site_packages=False,
)
def await_feishu_message(connection_id: str) -> dict[str, str]:
    """Block until one allow-listed Feishu message arrives.

    All imports needed at task execution time are local because Airflow writes
    this callable to a task-local virtualenv. The current Airflow Task SDK
    environment is inherited, so ``BaseHook`` can read the Connection without
    passing its password through task arguments or XCom.
    """
    import asyncio
    import contextlib
    import json
    import os
    import secrets
    from collections.abc import Mapping
    from datetime import datetime
    from pathlib import Path

    from airflow.sdk import BaseHook
    from lark_oapi.channel import FeishuChannel

    state_filename = "feishu-message-received-state.json"
    max_remembered_message_ids = 500

    def airflow_home() -> Path:
        return Path(os.environ.get("AIRFLOW_HOME", Path.home() / ".airflow"))

    def optional_string(value: object, field: str) -> str:
        if value is None:
            return ""
        if not isinstance(value, str):
            raise RuntimeError(f"Feishu Connection field {field!r} must be a string")
        return value

    def string_list(value: object, field: str) -> tuple[str, ...]:
        if value is None:
            return ()
        if not isinstance(value, list) or not all(isinstance(item, str) and item for item in value):
            raise RuntimeError(f"Feishu Connection extra field {field!r} must be a list of strings")
        return tuple(value)

    def read_configuration() -> dict[str, object]:
        try:
            connection = BaseHook.get_connection(connection_id)
        except Exception as error:
            raise RuntimeError(
                f"Feishu Airflow Connection {connection_id!r} is unavailable; create it in the Airflow UI"
            ) from error
        app_id = optional_string(connection.login, "login")
        app_secret = optional_string(connection.password, "password")
        if not app_id or not app_secret:
            raise RuntimeError(
                f"Feishu Airflow Connection {connection_id!r} requires login (App ID) and password (App Secret)"
            )
        try:
            extra = connection.extra_dejson
        except (TypeError, ValueError) as error:
            raise RuntimeError(f"Feishu Airflow Connection {connection_id!r} has invalid JSON extra") from error
        if not isinstance(extra, dict):
            raise RuntimeError(f"Feishu Airflow Connection {connection_id!r} extra must be a JSON object")
        return {
            "app_id": app_id,
            "app_secret": app_secret,
            "allowed_chat_ids": string_list(extra.get("allowed_chat_ids"), "allowed_chat_ids"),
            "allowed_sender_ids": string_list(extra.get("allowed_sender_ids"), "allowed_sender_ids"),
        }

    def read_seen_message_ids(path: Path) -> list[str]:
        try:
            value = json.loads(path.read_text(encoding="utf-8"))
            message_ids = value.get("message_ids", [])
        except (OSError, ValueError, AttributeError):
            return []
        if not isinstance(message_ids, list):
            return []
        return [message_id for message_id in message_ids if isinstance(message_id, str)][-max_remembered_message_ids:]

    def write_seen_message_ids(path: Path, message_ids: list[str]) -> None:
        path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        try:
            path.parent.chmod(0o700)
        except OSError:
            pass
        temporary = path.with_name(f".{path.name}.{secrets.token_hex(8)}.tmp")
        try:
            temporary.write_text(
                json.dumps({"message_ids": message_ids[-max_remembered_message_ids:]}, sort_keys=True),
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

    def string_value(source: object, *names: str) -> str:
        for name in names:
            if isinstance(source, Mapping):
                value = source.get(name)
            else:
                value = getattr(source, name, None)
            if isinstance(value, str) and value:
                return value
        return ""

    def message_metadata(message: object, configuration: Mapping[str, object]) -> dict[str, str] | None:
        message_id = string_value(message, "message_id", "id")
        conversation = getattr(message, "conversation", None)
        sender = getattr(message, "sender", None)
        chat_id = string_value(conversation, "chat_id", "id") or string_value(message, "chat_id")
        sender_id = string_value(sender, "open_id", "user_id", "union_id", "id") or string_value(
            message, "sender_id"
        )
        if not message_id:
            return None
        allowed_chat_ids = configuration["allowed_chat_ids"]
        allowed_sender_ids = configuration["allowed_sender_ids"]
        if (allowed_chat_ids and chat_id not in allowed_chat_ids) or (
            allowed_sender_ids and sender_id not in allowed_sender_ids
        ):
            return None
        return {
            "event": "feishu_message_received",
            "message_id": message_id,
            "chat_id": chat_id,
            "sender_id": sender_id,
            "message_type": string_value(message, "message_type", "type") or "unknown",
            "received_at": datetime.now().astimezone().isoformat(),
        }

    async def receive_one_message(configuration: Mapping[str, object]) -> dict[str, str]:
        loop = asyncio.get_running_loop()
        received: asyncio.Future[dict[str, str]] = loop.create_future()
        channel = FeishuChannel(app_id=configuration["app_id"], app_secret=configuration["app_secret"])

        @channel.on("message")
        async def handle_message(message: object) -> None:
            metadata = message_metadata(message, configuration)
            if metadata is not None and not received.done():
                received.set_result(metadata)

        connection = asyncio.create_task(channel.connect())
        try:
            done, _ = await asyncio.wait((received, connection), return_when=asyncio.FIRST_COMPLETED)
            if received in done:
                return received.result()
            connection.result()
            raise RuntimeError("Feishu long connection stopped before receiving a message")
        finally:
            if not connection.done():
                connection.cancel()
            with contextlib.suppress(asyncio.CancelledError):
                await connection

    async def receive_distinct_message(configuration: Mapping[str, object]) -> dict[str, str]:
        state_path = airflow_home() / state_filename
        while True:
            event = await receive_one_message(configuration)
            seen = read_seen_message_ids(state_path)
            if event["message_id"] in seen:
                # Long connections can replay an event after reconnecting.
                continue
            write_seen_message_ids(state_path, [*seen, event["message_id"]])
            return event

    return asyncio.run(receive_distinct_message(read_configuration()))


@task(task_id="record_message_metadata")
def log_feishu_message_metadata(event: dict[str, Any]) -> None:
    """Default action; replace this with an idempotent local automation task."""
    logging.getLogger(__name__).info(
        "Feishu message received: message_id=%s chat_id=%s sender_id=%s type=%s at=%s",
        event["message_id"],
        event["chat_id"],
        event["sender_id"],
        event["message_type"],
        event["received_at"],
    )


with DAG(
    dag_id=DAG_ID,
    description="Run when the configured Feishu app receives an allow-listed message.",
    schedule="@continuous",
    start_date=datetime(2026, 1, 1),
    catchup=False,
    max_active_runs=1,
    tags=["controlmymac", "event-driven", "feishu"],
) as dag:
    feishu_message = await_feishu_message(FEISHU_CONNECTION_ID)
    record_message_metadata = log_feishu_message_metadata(feishu_message)
    feishu_message >> record_message_metadata
