"""Focused tests for secure local SimpleAuth supervisor helpers."""
from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import stat
import tempfile
import unittest
from pathlib import Path

MODULE_PATH = Path(__file__).parents[1] / "Resources" / "airflow-supervisor.py"
SPEC = importlib.util.spec_from_file_location("airflow_supervisor", MODULE_PATH)
assert SPEC and SPEC.loader
supervisor = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(supervisor)


class SimpleAuthSupervisorTests(unittest.TestCase):
    def test_rotation_writes_only_fixed_user_with_user_only_permissions_and_no_output(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            home = Path(temporary_directory) / "airflow"
            output = io.StringIO()
            with contextlib.redirect_stdout(output), contextlib.redirect_stderr(output):
                first = supervisor.wait_for_simple_auth_password(
                    supervisor.rotate_simple_auth_password(home))
                second = supervisor.wait_for_simple_auth_password(
                    supervisor.rotate_simple_auth_password(home))
            password_file = supervisor.simple_auth_passwords_path(home)
            self.assertNotEqual(first, second)
            self.assertEqual(json.loads(password_file.read_text()), {"controlmymac": second})
            self.assertEqual(stat.S_IMODE(password_file.stat().st_mode), 0o600)
            self.assertEqual(stat.S_IMODE(home.stat().st_mode), 0o700)
            self.assertEqual(output.getvalue(), "")

    def test_runtime_configuration_uses_fixed_simple_auth_file_without_secret(self) -> None:
        home = Path("/tmp/airflow-home")
        configuration = supervisor.runtime_configuration(home, Path("/tmp/dags"), Path("/tmp/logs"))
        self.assertIn("auth_manager = airflow.api_fastapi.auth.managers.simple.simple_auth_manager.SimpleAuthManager", configuration)
        self.assertIn("simple_auth_manager_users = controlmymac:admin", configuration)
        self.assertIn("simple_auth_manager_all_admins = False", configuration)
        self.assertIn("simple_auth_manager_passwords_file = /tmp/airflow-home/simple-auth-passwords.json", configuration)
        self.assertIn("execution_api_server_url = http://127.0.0.1:50100/execution/", configuration)

    def test_environment_explicitly_sets_execution_api_server_url(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            airflow_home = Path(temporary_directory) / "airflow-home"
            first = supervisor.environment(
                Path("/tmp/python-home"),
                Path("/tmp/python-packages"),
                airflow_home,
                Path("/tmp/dags"),
                Path("/tmp/task-logs"),
            )
            second = supervisor.environment(
                Path("/tmp/python-home"),
                Path("/tmp/python-packages"),
                airflow_home,
                Path("/tmp/dags"),
                Path("/tmp/task-logs"),
            )
            secret_file = airflow_home / "api-auth-jwt-secret.json"
            self.assertEqual(
                first["AIRFLOW__CORE__EXECUTION_API_SERVER_URL"],
                "http://127.0.0.1:50100/execution/",
            )
            self.assertEqual(first["PYTHONPATH"], "/tmp/python-packages:/tmp/dags")
            self.assertEqual(first["AIRFLOW__API_AUTH__JWT_SECRET"], second["AIRFLOW__API_AUTH__JWT_SECRET"])
            self.assertGreaterEqual(len(first["AIRFLOW__API_AUTH__JWT_SECRET"]), 64)
            self.assertEqual(stat.S_IMODE(secret_file.stat().st_mode), 0o600)


if __name__ == "__main__":
    unittest.main()
