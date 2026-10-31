#!/bin/bash
# Remove the Airflow-only ControlMyMac application while preserving user DAGs,
# Airflow metadata, logs, and installed Python packages for a later reinstall.
set -euo pipefail

REPO="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
eval "$(env -u MAKEFLAGS make -s --no-print-directory -C "$REPO" env)"
[ "$(id -u)" -eq 0 ] || { echo "请用 sudo 运行：sudo bash $0"; exit 1; }

TARGET_USER="${SUDO_USER:-$(stat -f%Su /dev/console)}"
TARGET_HOME=$(dscl . -read "/Users/$TARGET_USER" NFSHomeDirectory | awk '{print $2}')
TARGET_UID=$(id -u "$TARGET_USER")

launchctl bootout "gui/$TARGET_UID/$AIRFLOW_LABEL" 2>/dev/null || true
launchctl bootout "gui/$TARGET_UID/$UI_LABEL" 2>/dev/null || true
# Also clean up services installed by earlier listener-based releases.
launchctl bootout system/com.liuzheng.controlmymac 2>/dev/null || true
launchctl bootout "gui/$TARGET_UID/com.liuzheng.controlmymac.focus" 2>/dev/null || true
launchctl bootout "gui/$TARGET_UID/com.liuzheng.controlmymac.listener" 2>/dev/null || true

rm -f "$TARGET_HOME/Library/LaunchAgents/$AIRFLOW_LABEL.plist" \
      "$TARGET_HOME/Library/LaunchAgents/$UI_LABEL.plist" \
      "$TARGET_HOME/Library/LaunchAgents/com.liuzheng.controlmymac.focus.plist" \
      "$TARGET_HOME/Library/LaunchAgents/com.liuzheng.controlmymac.listener.plist" \
      /Library/LaunchDaemons/com.liuzheng.controlmymac.plist \
      /usr/local/bin/controlmymacd /usr/local/bin/controlmymac-focusd
pkill -x ControlMyMac 2>/dev/null || true
rm -rf "$APP_DEST"
echo "已卸载应用和 LaunchAgent。Airflow DAG、状态、日志和依赖均已保留。"
