"""Manually submit and wait for a phase-one ControlMyMac operation request.

Copy this file and ``controlmymac_operation_client.py`` into ControlMyMac's
user DAG directory. The ControlMyMac app must remain open while this DAG runs.
The DAG never executes network commands; after Touch ID/password approval the
app copies a reviewed command for the user to run manually in Terminal.
"""
from __future__ import annotations

import asyncio
from datetime import datetime
from typing import Any

from airflow.exceptions import AirflowException
from airflow.sdk import Context, DAG, task
from airflow.triggers.base import BaseTrigger, TriggerEvent

from controlmymac_operation_client import ControlMyMacOperationError, create_configure_en9, status

DAG_ID = "privileged_operation_demo"
POLL_SECONDS = 3


class OperationStatusTrigger(BaseTrigger):
    def __init__(self, request_id: str) -> None:
        super().__init__()
        self.request_id = request_id

    def serialize(self) -> tuple[str, dict[str, Any]]:
        return ("privileged_operation_demo.OperationStatusTrigger", {"request_id": self.request_id})

    async def run(self):
        while True:
            try:
                response = await asyncio.to_thread(status, self.request_id)
            except ControlMyMacOperationError as error:
                yield TriggerEvent({"error": str(error)})
                return
            state = response.get("state")
            if state in {"succeeded", "failed", "cancelled", "expired", "manual_execution_required"}:
                yield TriggerEvent(response)
                return
            await asyncio.sleep(POLL_SECONDS)


@task(task_id="await_operation")
def await_operation(request_id: str) -> dict[str, Any]:
    raise AirflowException("This TaskFlow task is replaced by the deferrable sensor below")


from airflow.sdk import BaseSensorOperator


class OperationStatusSensor(BaseSensorOperator):
    template_fields = ("request_id",)

    def __init__(self, *, request_id: str, **kwargs: Any) -> None:
        super().__init__(**kwargs)
        self.request_id = request_id

    def execute(self, context: Context) -> None:
        self.defer(trigger=OperationStatusTrigger(self.request_id), method_name="execute_complete")

    def execute_complete(self, context: Context, event: dict[str, Any] | None = None) -> dict[str, Any]:
        if not event:
            raise AirflowException("ControlMyMac returned no operation result")
        if event.get("error"):
            raise AirflowException(event["error"])
        return event


@task(task_id="submit_configure_en9")
def submit_configure_en9() -> str:
    try:
        response = create_configure_en9(
            mac_address="7c:8a:e1:8d:ab:2f",
            search_domain="cn1.global.ctrip.com",
            title="配置 Ctrip 网络",
            description="将为 en9 准备已注册的 MAC 地址和 DNS 搜索域；命令需在 Terminal 手动执行。",
        )
    except ControlMyMacOperationError as error:
        raise AirflowException(str(error)) from error
    request_id = response.get("requestID", {}).get("value")
    if response.get("state") != "pending_authorization" or not isinstance(request_id, str):
        raise AirflowException(f"Unexpected ControlMyMac response: {response!r}")
    return request_id


@task(task_id="record_terminal_handoff")
def record_terminal_handoff(result: dict[str, Any]) -> None:
    if result.get("state") != "manual_execution_required":
        raise AirflowException(f"Operation did not reach manual terminal handoff: {result!r}")


with DAG(
    dag_id=DAG_ID,
    description="Submit an allow-listed ControlMyMac request and wait for manual terminal handoff.",
    schedule=None,
    start_date=datetime(2026, 1, 1),
    catchup=False,
    max_active_runs=1,
    tags=["controlmymac", "manual-approval", "phase-one"],
) as dag:
    request_id = submit_configure_en9()
    result = OperationStatusSensor(task_id="await_terminal_handoff", request_id=request_id)
    record = record_terminal_handoff(result.output)
    request_id >> result >> record
