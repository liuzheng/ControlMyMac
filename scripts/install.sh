#!/bin/bash
# Install the Airflow-only ControlMyMac application. Root is required only for
# /Applications and the login LaunchAgent; no privileged daemon is installed.
set -euo pipefail

REPO="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
eval "$(env -u MAKEFLAGS make -s --no-print-directory -C "$REPO" env)"
QUIET=0
[ "${1:-}" = "--quiet" ] && QUIET=1
say() { [ "$QUIET" = 1 ] || echo "$@"; }
[ "$(id -u)" -eq 0 ] || { echo "请用 sudo 运行：sudo bash $0"; exit 1; }

TARGET_USER="${SUDO_USER:-$(stat -f%Su /dev/console)}"
TARGET_HOME=$(dscl . -read "/Users/$TARGET_USER" NFSHomeDirectory | awk '{print $2}')
TARGET_UID=$(id -u "$TARGET_USER")
[ -n "$TARGET_HOME" ] && [ -d "$TARGET_HOME" ] || { echo "定位不到用户 $TARGET_USER 的家目录，中止"; exit 1; }

AIRFLOW_HOME="$TARGET_HOME/Library/Application Support/ControlMyMac/airflow"
AIRFLOW_DAGS="$TARGET_HOME/Library/Application Support/ControlMyMac/dags"
AIRFLOW_LOG_ROOT="$TARGET_HOME/Library/Logs/ControlMyMac/Airflow"
AIRFLOW_STATUS="$AIRFLOW_HOME/service-status.json"
AIRFLOW_PLIST="$TARGET_HOME/Library/LaunchAgents/$AIRFLOW_LABEL.plist"
UI_PLIST="$TARGET_HOME/Library/LaunchAgents/$UI_LABEL.plist"
AIRFLOW_SERVICE_LOG="$AIRFLOW_LOG_ROOT/service/$(date +%F)"

[ -d "$REPO/$BUNDLE" ] || { echo "缺少 $REPO/$BUNDLE，先在仓库里跑一次 make bundle"; exit 1; }

bootout_job() {
  local domain="$1" label="$2"
  launchctl bootout "$domain/$label" 2>/dev/null || true
}

# Remove services from pre-Airflow-only releases. Failures are benign when an
# older release was never installed.
say "移除旧监听服务…"
bootout_job system com.liuzheng.controlmymac
bootout_job "gui/$TARGET_UID" com.liuzheng.controlmymac.focus
bootout_job "gui/$TARGET_UID" com.liuzheng.controlmymac.listener
rm -f /Library/LaunchDaemons/com.liuzheng.controlmymac.plist \
      /usr/local/bin/controlmymacd /usr/local/bin/controlmymac-focusd \
      "$TARGET_HOME/Library/LaunchAgents/com.liuzheng.controlmymac.focus.plist" \
      "$TARGET_HOME/Library/LaunchAgents/com.liuzheng.controlmymac.listener.plist"

bootout_job "gui/$TARGET_UID" "$AIRFLOW_LABEL"
bootout_job "gui/$TARGET_UID" "$UI_LABEL"

install -d -m 700 -o "$TARGET_USER" -g staff "$AIRFLOW_DAGS" "$AIRFLOW_HOME" \
  "$AIRFLOW_SERVICE_LOG" "$AIRFLOW_LOG_ROOT/tasks/$(date +%F)" \
  "$AIRFLOW_LOG_ROOT/maintenance/$(date +%F)" "$TARGET_HOME/Library/LaunchAgents"

say "安装菜单栏 App…"
pkill -x ControlMyMac 2>/dev/null || true
NEW_APP="${APP_DEST}.new.$$"
OLD_APP="${APP_DEST}.previous.$$"
rm -rf "$NEW_APP" "$OLD_APP"
cp -R "$REPO/$BUNDLE" "$NEW_APP"
chown -R root:wheel "$NEW_APP"
[ ! -e "$APP_DEST" ] || mv "$APP_DEST" "$OLD_APP"
if ! mv "$NEW_APP" "$APP_DEST"; then
  rm -rf "$NEW_APP"
  [ ! -e "$OLD_APP" ] || mv "$OLD_APP" "$APP_DEST"
  echo "!! App bundle 替换失败，已恢复旧版本"
  exit 1
fi
rm -rf "$OLD_APP"

PYTHON_RUNTIME_BIN="$APP_DEST/Contents/Frameworks/Python.framework/Versions/Current/bin/python3"
PYTHON_PACKAGES="$TARGET_HOME/.controlmymac/python-packages"
PYTHON_STATUS="$TARGET_HOME/.controlmymac/python-packages.status"
AIRFLOW_READY=1
install -d -m 700 -o "$TARGET_USER" -g staff "$TARGET_HOME/.controlmymac"
if ! sudo -u "$TARGET_USER" -H /bin/bash "$REPO/scripts/install-python-dependencies.sh" \
  --python "$PYTHON_RUNTIME_BIN" --target "$PYTHON_PACKAGES" --status "$PYTHON_STATUS"; then
  AIRFLOW_READY=0
  printf '{"phase":"failed","message":"Unable to install apache-airflow==3.3.2; see %s"}\n' "$PYTHON_STATUS" > "$AIRFLOW_STATUS"
  chown "$TARGET_USER":staff "$AIRFLOW_STATUS"
fi

if [ "$AIRFLOW_READY" = 1 ]; then
  AIRFLOW_CONFIG="$AIRFLOW_HOME/airflow.cfg"
  AIRFLOW_SIMPLE_AUTH_PASSWORDS="$AIRFLOW_HOME/simple-auth-passwords.json"
  AIRFLOW_RETENTION="$AIRFLOW_HOME/log-retention.json"
  umask 077
  printf '[core]\ndags_folder = %s\nload_examples = False\nauth_manager = airflow.api_fastapi.auth.managers.simple.simple_auth_manager.SimpleAuthManager\nsimple_auth_manager_users = controlmymac:admin\nsimple_auth_manager_all_admins = False\nsimple_auth_manager_passwords_file = %s\nexecution_api_server_url = http://127.0.0.1:50100/execution/\n\n[database]\nsql_alchemy_conn = sqlite:///%s/airflow.db\n\n[logging]\nbase_log_folder = %s\nremote_logging = False\n' \
    "$AIRFLOW_DAGS" "$AIRFLOW_SIMPLE_AUTH_PASSWORDS" "$AIRFLOW_HOME" "$AIRFLOW_LOG_ROOT/tasks/$(date +%F)" > "$AIRFLOW_CONFIG.tmp"
  chown "$TARGET_USER":staff "$AIRFLOW_CONFIG.tmp"
  chmod 600 "$AIRFLOW_CONFIG.tmp"
  mv -f "$AIRFLOW_CONFIG.tmp" "$AIRFLOW_CONFIG"
  if [ ! -f "$AIRFLOW_RETENTION" ]; then
    printf '{"days":30}\n' > "$AIRFLOW_RETENTION.tmp"
    chown "$TARGET_USER":staff "$AIRFLOW_RETENTION.tmp"
    chmod 600 "$AIRFLOW_RETENTION.tmp"
    mv -f "$AIRFLOW_RETENTION.tmp" "$AIRFLOW_RETENTION"
  fi
  sed -e "s|__PYTHON__|$PYTHON_RUNTIME_BIN|g" \
      -e "s|__SUPERVISOR__|$APP_DEST/Contents/Resources/airflow-supervisor.py|g" \
      -e "s|__AIRFLOW_HOME__|$AIRFLOW_HOME|g" -e "s|__DAGS_DIR__|$AIRFLOW_DAGS|g" \
      -e "s|__LOG_ROOT__|$AIRFLOW_LOG_ROOT|g" -e "s|__PYTHON_PACKAGES__|$PYTHON_PACKAGES|g" \
      -e "s|__SERVICE_LOG__|$AIRFLOW_SERVICE_LOG|g" "$REPO/$AIRFLOW_TEMPLATE" > "$AIRFLOW_PLIST.tmp"
  plutil -lint "$AIRFLOW_PLIST.tmp" >/dev/null || { rm -f "$AIRFLOW_PLIST.tmp"; echo "!! Airflow LaunchAgent 模板无效"; exit 1; }
  chown "$TARGET_USER":staff "$AIRFLOW_PLIST.tmp"
  chmod 644 "$AIRFLOW_PLIST.tmp"
  mv -f "$AIRFLOW_PLIST.tmp" "$AIRFLOW_PLIST"
  launchctl enable "gui/$TARGET_UID/$AIRFLOW_LABEL"
  launchctl bootstrap "gui/$TARGET_UID" "$AIRFLOW_PLIST" 2>/dev/null || say "（Airflow LaunchAgent 加载失败；请查看 $AIRFLOW_STATUS）"
else
  say "Airflow 不可用：$(cat "$AIRFLOW_STATUS" 2>/dev/null || echo '依赖验证失败')"
fi

install -m 644 -o "$TARGET_USER" -g staff "$REPO/Resources/$UI_LABEL.plist" "$UI_PLIST"
launchctl bootstrap "gui/$TARGET_UID" "$UI_PLIST" 2>/dev/null || say "（登录自启 Agent 加载失败）"
launchctl asuser "$TARGET_UID" /usr/bin/open -g "$APP_DEST" || sudo -u "$TARGET_USER" /usr/bin/open -g "$APP_DEST" || true
say "完成。Airflow 服务由 $AIRFLOW_LABEL 管理。"
