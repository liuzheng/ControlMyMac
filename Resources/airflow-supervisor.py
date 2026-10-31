#!/usr/bin/env python3
"""LaunchAgent supervisor for ControlMyMac's private Apache Airflow service.

Only documented Airflow CLI components are run: ``db migrate``, ``scheduler``,
``dag-processor``, ``triggerer``, and the loopback-only ``api-server``.  The
implementation deliberately does not use ``airflow standalone`` or private APIs.
"""
from __future__ import annotations

import hashlib
import json
import os
import secrets
import signal
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.request
from datetime import date, datetime, timedelta
from pathlib import Path
from typing import NoReturn

AIRFLOW_VERSION = "3.3.2"
ENDPOINT_HOST = "127.0.0.1"
ENDPOINT_PORT = "50100"
DEFAULT_RETENTION_DAYS = 30
SIMPLE_AUTH_USERNAME = "controlmymac"
SIMPLE_AUTH_ROLE = "admin"
SIMPLE_AUTH_PASSWORDS_FILENAME = "simple-auth-passwords.json"
CHILDREN: list[subprocess.Popen[str]] = []
STOPPING = False


def write_private_json(path: Path, value: dict[str, object]) -> None:
    """Atomically write user-only local state without exposing its contents."""
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    try:
        path.parent.chmod(0o700)
    except OSError:
        pass
    temporary = path.parent / f".{path.name}.{secrets.token_hex(16)}.tmp"
    descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as output:
            json.dump(value, output, sort_keys=True)
            output.flush()
            os.fsync(output.fileno())
        os.chmod(temporary, 0o600)
        os.replace(temporary, path)
        os.chmod(path, 0o600)
    except BaseException:
        try:
            temporary.unlink()
        except FileNotFoundError:
            pass
        raise


def write_json(path: Path, value: dict[str, object]) -> None:
    write_private_json(path, value)


def write_status(path: Path, phase: str, message: str) -> None:
    write_json(path, {"phase": phase, "message": message, "updatedAt": datetime.now().isoformat()})


def simple_auth_passwords_path(airflow_home: Path) -> Path:
    return airflow_home / SIMPLE_AUTH_PASSWORDS_FILENAME


def rotate_simple_auth_password(airflow_home: Path) -> Path:
    """Replace the sole SimpleAuth password before Airflow can initialize.

    Airflow prints passwords it generates for missing users, so ControlMyMac
    pre-populates the configured file and never emits the secret itself.
    """
    path = simple_auth_passwords_path(airflow_home)
    write_private_json(path, {SIMPLE_AUTH_USERNAME: secrets.token_urlsafe(32)})
    return path


def wait_for_simple_auth_password(path: Path, deadline: float = 2) -> str:
    """Confirm the locally generated record is ready without logging its value."""
    end = time.monotonic() + deadline
    while time.monotonic() < end:
        try:
            value = json.loads(path.read_text(encoding="utf-8"))
            password = value.get(SIMPLE_AUTH_USERNAME) if isinstance(value, dict) else None
            if set(value) == {SIMPLE_AUTH_USERNAME} and isinstance(password, str) and password:
                if path.stat().st_mode & 0o077:
                    raise RuntimeError("SimpleAuth credential file permissions are unsafe")
                return password
        except (OSError, json.JSONDecodeError, RuntimeError):
            pass
        time.sleep(0.05)
    raise RuntimeError("SimpleAuth credential record was not created safely")


def fail(message: str, status_path: Path, code: int = 1) -> NoReturn:
    write_status(status_path, "failed", message)
    print(message, file=sys.stderr, flush=True)
    raise SystemExit(code)


def bundle_root() -> Path:
    # Resources/airflow-supervisor.py → Contents → ControlMyMac.app
    return Path(__file__).resolve().parents[2]


def validated_runtime(status_path: Path) -> tuple[Path, Path]:
    root = bundle_root()
    manifest_path = root / "Contents/Resources/python-runtime.json"
    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        fail(f"Python runtime manifest invalid: {error}", status_path)
    if not str(manifest.get("runtimeVersion", "")).startswith("3.14."):
        fail("Python runtime must be version 3.14", status_path)
    for relative, expected in manifest.get("files", {}).items():
        candidate = (root / relative).resolve()
        if root not in candidate.parents or not candidate.is_file():
            fail(f"Python runtime file missing: {relative}", status_path)
        actual = hashlib.sha256(candidate.read_bytes()).hexdigest()
        if actual.lower() != str(expected).lower():
            fail(f"Python runtime checksum mismatch: {relative}", status_path)
    executable = (root / manifest.get("executable", "")).resolve()
    home = (root / manifest.get("home", "")).resolve()
    if root not in executable.parents or not executable.is_file() or not os.access(executable, os.X_OK):
        fail("Python runtime executable is unavailable", status_path)
    if root not in home.parents or not home.is_dir():
        fail("Python runtime home is unavailable", status_path)
    return executable, home


def runtime_configuration(airflow_home: Path, dags: Path, task_log: Path) -> str:
    return f"""[core]
dags_folder = {dags}
load_examples = False
auth_manager = airflow.api_fastapi.auth.managers.simple.simple_auth_manager.SimpleAuthManager
simple_auth_manager_users = {SIMPLE_AUTH_USERNAME}:{SIMPLE_AUTH_ROLE}
simple_auth_manager_all_admins = False
simple_auth_manager_passwords_file = {simple_auth_passwords_path(airflow_home)}
execution_api_server_url = http://{ENDPOINT_HOST}:{ENDPOINT_PORT}/execution/

[database]
sql_alchemy_conn = sqlite:///{airflow_home / 'airflow.db'}

[logging]
base_log_folder = {task_log}
remote_logging = False
"""


def provision_workspace(airflow_home: Path, dags: Path, log_root: Path, today: str) -> Path:
    task_log = log_root / "tasks" / today
    for directory in (dags, airflow_home, log_root / "service" / today, task_log,
                      log_root / "maintenance" / today):
        directory.mkdir(parents=True, exist_ok=True, mode=0o700)
        try:
            directory.chmod(0o700)
        except OSError:
            pass
    configuration = airflow_home / "airflow.cfg"
    temporary = configuration.with_suffix(".tmp")
    temporary.write_text(runtime_configuration(airflow_home, dags, task_log), encoding="utf-8")
    temporary.chmod(0o600)
    temporary.replace(configuration)
    return task_log


def redirect_service_logs(log_root: Path, today: str) -> None:
    service_dir = log_root / "service" / today
    service_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
    for descriptor, name in ((sys.stdout.fileno(), "stdout.log"), (sys.stderr.fileno(), "stderr.log")):
        handle = os.open(service_dir / name, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
        os.dup2(handle, descriptor)
        os.close(handle)


def clean_expired_logs(log_root: Path, airflow_home: Path, retention_days: int, today: date) -> None:
    root = log_root.resolve()
    cutoff = today - timedelta(days=retention_days)
    deleted, problems = 0, []
    for category in ("service", "tasks", "maintenance"):
        category_path = root / category
        if not category_path.exists():
            continue
        if category_path.is_symlink() or not category_path.is_dir():
            problems.append(f"unsafe log category skipped: {category_path}")
            continue
        for entry in category_path.iterdir():
            try:
                entry_date = datetime.strptime(entry.name, "%Y-%m-%d").date()
            except ValueError:
                continue
            resolved = entry.resolve()
            if entry.is_symlink() or root not in resolved.parents or not entry.is_dir():
                problems.append(f"unsafe log path skipped: {entry}")
            elif entry_date < cutoff:
                unsafe_children = [child for child in entry.rglob("*")
                                   if child.is_symlink() or root not in child.resolve().parents]
                if unsafe_children:
                    problems.append(f"unsafe log path skipped: {unsafe_children[0]}")
                    continue
                try:
                    shutil.rmtree(entry)
                    deleted += 1
                except OSError as error:
                    problems.append(f"unable to delete {entry}: {error}")
    message = f"deleted {deleted} expired log directories" if not problems else "; ".join(problems)
    maintenance = root / "maintenance" / today.isoformat()
    maintenance.mkdir(parents=True, exist_ok=True, mode=0o700)
    with (maintenance / "cleanup.log").open("a", encoding="utf-8") as output:
        output.write(f"{datetime.now().isoformat()} {message}\n")
    write_json(airflow_home / "cleanup-status.json", {"deletedItems": deleted, "diagnostic": message,
                                                        "updatedAt": datetime.now().isoformat()})


def retention_days(airflow_home: Path) -> int:
    try:
        value = int(json.loads((airflow_home / "log-retention.json").read_text(encoding="utf-8"))["days"])
        return value if value > 0 else DEFAULT_RETENTION_DAYS
    except (OSError, ValueError, KeyError, TypeError, json.JSONDecodeError):
        return DEFAULT_RETENTION_DAYS


def environment(home: Path, package_dir: Path, airflow_home: Path, dags: Path, task_log: Path) -> dict[str, str]:
    """Create the shared Airflow environment, including one stable execution JWT.

    Airflow 3 execution workers authenticate to the API with a JWT.  Leaving
    ``api_auth/jwt_secret`` unset causes each process to generate a different
    in-memory key, so LocalExecutor workers receive HTTP 403 before any task
    code can run.
    """
    jwt_secret_path = airflow_home / "api-auth-jwt-secret.json"
    try:
        payload = json.loads(jwt_secret_path.read_text(encoding="utf-8"))
        jwt_secret = payload["jwtSecret"]
        if not isinstance(jwt_secret, str) or len(jwt_secret) < 64:
            raise ValueError("invalid API JWT secret")
    except (OSError, ValueError, KeyError, TypeError, json.JSONDecodeError):
        jwt_secret = secrets.token_urlsafe(64)
        write_private_json(jwt_secret_path, {"jwtSecret": jwt_secret})
    return {
        "HOME": str(Path.home()), "PATH": "/usr/bin:/bin", "LANG": "C", "PYTHONHOME": str(home),
        "PYTHONNOUSERSITE": "1", "PYTHONPATH": os.pathsep.join((str(package_dir), str(dags))),
        "AIRFLOW_HOME": str(airflow_home),
        "AIRFLOW_CONFIG": str(airflow_home / "airflow.cfg"), "AIRFLOW__CORE__DAGS_FOLDER": str(dags),
        "AIRFLOW__CORE__EXECUTION_API_SERVER_URL": f"http://{ENDPOINT_HOST}:{ENDPOINT_PORT}/execution/",
        "AIRFLOW__API_AUTH__JWT_SECRET": jwt_secret,
        "AIRFLOW__LOGGING__BASE_LOG_FOLDER": str(task_log),
    }


def airflow_command(python: Path, subcommand: list[str]) -> list[str]:
    return [str(python), "-s", "-m", "airflow", *subcommand]


def validate_airflow(python: Path, env: dict[str, str], status_path: Path) -> None:
    result = subprocess.run([str(python), "-s", "-c", "import airflow; print(airflow.__version__)"],
                            env=env, text=True, capture_output=True)
    version = result.stdout.strip()
    if result.returncode != 0 or version != AIRFLOW_VERSION:
        detail = result.stderr.strip() or version or "package is not installed"
        fail(f"apache-airflow=={AIRFLOW_VERSION} is required: {detail}", status_path)


def launch(python: Path, env: dict[str, str], arguments: list[str], status_path: Path) -> subprocess.Popen[str]:
    try:
        return subprocess.Popen(airflow_command(python, arguments), env=env, text=True, start_new_session=True)
    except OSError as error:
        fail(f"Unable to start Airflow {' '.join(arguments)}: {error}", status_path)


def wait_for_api(status_path: Path, deadline: float = 30) -> None:
    """Wait for the loopback API before advertising a ready service state."""
    end = time.monotonic() + deadline
    endpoint = f"http://{ENDPOINT_HOST}:{ENDPOINT_PORT}"
    while time.monotonic() < end:
        try:
            with urllib.request.urlopen(endpoint, timeout=1) as response:
                if response.status < 500:
                    write_status(status_path, "ready", f"Airflow is ready at {endpoint}")
                    return
        except (urllib.error.URLError, TimeoutError):
            pass
        for child in CHILDREN:
            code = child.poll()
            if code is not None:
                stop_children(signal.SIGTERM, None)
                fail(f"Required Airflow component exited with status {code}; see the service log", status_path,
                     code or 1)
        time.sleep(0.5)
    stop_children(signal.SIGTERM, None)
    fail(f"Airflow API did not become ready at {endpoint} within {int(deadline)} seconds", status_path)


def stop_children(_: int, __: object) -> None:
    global STOPPING
    STOPPING = True
    for child in CHILDREN:
        if child.poll() is None:
            try:
                os.killpg(child.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass


def main() -> int:
    airflow_home = Path(os.environ["CONTROLMYMAC_AIRFLOW_HOME"])
    dags = Path(os.environ["CONTROLMYMAC_AIRFLOW_DAGS"])
    log_root = Path(os.environ["CONTROLMYMAC_AIRFLOW_LOG_ROOT"])
    package_dir = Path(os.environ["CONTROLMYMAC_PYTHON_PACKAGES"])
    status_path = airflow_home / "service-status.json"
    current_date = date.today()
    task_log = provision_workspace(airflow_home, dags, log_root, current_date.isoformat())
    redirect_service_logs(log_root, current_date.isoformat())
    clean_expired_logs(log_root, airflow_home, retention_days(airflow_home), current_date)

    try:
        credentials_path = rotate_simple_auth_password(airflow_home)
        wait_for_simple_auth_password(credentials_path)
    except (OSError, RuntimeError):
        fail("SimpleAuth credential rotation failed", status_path)

    python, python_home = validated_runtime(status_path)
    if not package_dir.is_dir():
        fail(f"apache-airflow=={AIRFLOW_VERSION} is not installed in {package_dir}", status_path)
    env = environment(python_home, package_dir, airflow_home, dags, task_log)
    validate_airflow(python, env, status_path)
    migration = subprocess.run(airflow_command(python, ["db", "migrate"]), env=env, text=True)
    if migration.returncode != 0:
        fail("Airflow metadata migration failed; see the service log", status_path, migration.returncode)

    write_status(status_path, "starting", "Airflow components are starting")
    signal.signal(signal.SIGTERM, stop_children)
    signal.signal(signal.SIGINT, stop_children)
    global CHILDREN
    CHILDREN = [
        launch(python, env, ["scheduler"], status_path),
        launch(python, env, ["dag-processor"], status_path),
        launch(python, env, ["triggerer"], status_path),
        launch(python, env, ["api-server", "--host", ENDPOINT_HOST, "--port", ENDPOINT_PORT], status_path),
    ]
    write_status(status_path, "starting", "Airflow is waiting for local API readiness")
    wait_for_api(status_path)
    while not STOPPING:
        now = date.today()
        if now != current_date:
            current_date = now
            task_log = provision_workspace(airflow_home, dags, log_root, now.isoformat())
            redirect_service_logs(log_root, now.isoformat())
            clean_expired_logs(log_root, airflow_home, retention_days(airflow_home), now)
        for child in CHILDREN:
            code = child.poll()
            if code is not None:
                stop_children(signal.SIGTERM, None)
                fail(f"Required Airflow component exited with status {code}; see {log_root / 'service' / current_date.isoformat()}",
                     status_path, code or 1)
        time.sleep(1)
    for child in CHILDREN:
        try:
            child.wait(timeout=20)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(child.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
    write_status(status_path, "stopped", "Airflow stopped by launchd")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
