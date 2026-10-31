#!/bin/bash
# Install Airflow and application Python dependencies into a user-owned target.
# The interpreter must be the bundled Python 3.14 executable.
set -euo pipefail

PYTHON=""
TARGET=""
STATUS=""
CONSTRAINT="https://raw.githubusercontent.com/apache/airflow/constraints-3.3.2/constraints-3.14.txt"
AIRFLOW_SPEC="apache-airflow==3.3.2"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --python) PYTHON="$2"; shift 2 ;;
    --target) TARGET="$2"; shift 2 ;;
    --status) STATUS="$2"; shift 2 ;;
    --constraint) CONSTRAINT="$2"; shift 2 ;;
    --airflow) AIRFLOW_SPEC="$2"; shift 2 ;;
    *) echo "未知参数：$1" >&2; exit 2 ;;
  esac
done

[ -x "$PYTHON" ] || { echo "bundled Python 不可执行：$PYTHON" >&2; exit 1; }
[ -n "$TARGET" ] || { echo "缺少 --target" >&2; exit 1; }

PARENT="$(dirname "$TARGET")"
mkdir -p "$PARENT"
STATUS="${STATUS:-$PARENT/python-packages.status}"
write_status() {
  local state="$1" detail="${2:-}"
  printf 'state=%s\nupdated_at=%s\nerror=%s\n' \
    "$state" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$detail" > "$STATUS.tmp"
  mv -f "$STATUS.tmp" "$STATUS"
}

TEMP_TARGET="$(mktemp -d "$PARENT/.python-packages.XXXXXX")"
PIP_ROOT="$(mktemp -d "$PARENT/.python-pip.XXXXXX")"
cleanup() { rm -rf "$TEMP_TARGET" "$PIP_ROOT"; }
trap cleanup EXIT

write_status installing

# The pkg's standard Python includes ensurepip but does not modify the signed
# framework here. Bootstrap pip into a temporary import location instead.
"$PYTHON" -m ensurepip --upgrade --default-pip --root "$PIP_ROOT" >/dev/null
PIP_SITE="$(/usr/bin/find "$PIP_ROOT" -type d -path '*/site-packages' -print -quit)"
[ -n "$PIP_SITE" ] || { write_status failed "ensurepip 未生成 site-packages"; exit 1; }

PIP_ARGS=(
  --disable-pip-version-check
  --no-input
  --no-cache-dir
  --upgrade
  --ignore-installed
  --target "$TEMP_TARGET"
  "$AIRFLOW_SPEC"
  --constraint "$CONSTRAINT"
)
# 默认使用阿里云 PyPI 镜像；部署环境可通过 PIP_INDEX_URL 覆盖。
PIP_ARGS+=(--index-url "${PIP_INDEX_URL:-https://mirrors.aliyun.com/pypi/simple}")

if ! PYTHONPATH="$PIP_SITE" "$PYTHON" -m pip install "${PIP_ARGS[@]}"; then
  write_status failed "pip 安装失败；原有依赖目录未替换"
  exit 1
fi

if [ -e "$TARGET" ]; then
  OLD_TARGET="$(mktemp -d "$PARENT/.python-packages-old.XXXXXX")"
  rmdir "$OLD_TARGET"
  mv "$TARGET" "$OLD_TARGET"
  mv "$TEMP_TARGET" "$TARGET"
  rm -rf "$OLD_TARGET"
else
  mv "$TEMP_TARGET" "$TARGET"
fi

write_status installed
printf 'Python 依赖已安装到：%s\n' "$TARGET"
