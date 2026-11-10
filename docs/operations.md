# ControlMyMac 运维指南

本文面向本机安装、更新、恢复和卸载 ControlMyMac 的管理员。应用支持 macOS 12+，并为当前登录用户管理本地 Airflow；不要以 root 身份构建项目。

## 安装与更新

在仓库根目录执行：

```bash
make install
```

该命令会先以当前用户运行 release 构建和 bundle，再通过 `sudo` 将新 App 安装到 `/Applications/ControlMyMac.app`。它会注册以下当前用户域 LaunchAgent：

```text
com.liuzheng.controlmymac.airflow  管理 Airflow supervisor
com.liuzheng.controlmymac.ui       登录时以后台方式打开菜单栏 App
```

安装会移除旧版 root daemon、focus/listener helper 及相关 plist，但会保留当前用户的 DAG、Airflow 数据、日志和 Python 包。若需使用其他 PyPI 镜像：

```bash
PIP_INDEX_URL=https://pypi.org/simple make install
```

安装过程会下载 `apache-airflow==3.3.2`。若下载或验证失败，App 可能已更新，但 Airflow 不会被加载；查看 `~/.controlmymac/python-packages.status`，修正问题后再次运行 `make install`。

## 服务状态与日常操作

菜单栏和设置页每 3 秒读取服务状态。Airflow 仅在以下条件同时满足时显示“已就绪”：Airflow LaunchAgent 已加载，且 `http://127.0.0.1:50100` 可在非 5xx 状态响应。服务启动会执行数据库迁移，再启动 scheduler、dag-processor、triggerer 与 loopback API server。

设置页可启动、停止、重启、打开 Airflow、打开 DAG/日志目录、查看 runtime/依赖状态、管理日志保留期和复制当前管理员密码。退出菜单栏 App 不会停止 Airflow。

### 停止后的恢复

当前“停止”会从用户 launchd 域 `bootout` Airflow job。由于“启动”不会对已卸载的 job 执行 bootstrap，停止后不能在设置页恢复时，请重新运行：

```bash
make install
```

这是当前实现的恢复路径；不要通过复制或编辑 App bundle 内的 plist 修复服务。

## 状态和日志位置

| 路径                                                                            | 内容                                     |
| ------------------------------------------------------------------------------- | ---------------------------------------- |
| `~/Library/Application Support/ControlMyMac/dags/`                              | 用户 DAG；唯一受支持 DAG 目录            |
| `~/Library/Application Support/ControlMyMac/airflow/airflow.cfg`                | 自动生成的、带绝对路径的 Airflow 配置    |
| `~/Library/Application Support/ControlMyMac/airflow/service-status.json`        | 失败、启动和就绪状态的诊断               |
| `~/Library/Application Support/ControlMyMac/airflow/simple-auth-passwords.json` | `controlmymac` SimpleAuth 密码；0600     |
| `~/Library/Application Support/ControlMyMac/airflow/api-auth-jwt-secret.json`   | 内部 execution API JWT；0600             |
| `~/Library/Application Support/ControlMyMac/airflow/log-retention.json`         | 日志保留天数；0600                       |
| `~/Library/Application Support/ControlMyMac/airflow/cleanup-status.json`        | 最近日志清理结果                         |
| `~/Library/Logs/ControlMyMac/Airflow/service/YYYY-MM-DD/`                       | supervisor 的 `stdout.log`、`stderr.log` |
| `~/Library/Logs/ControlMyMac/Airflow/tasks/YYYY-MM-DD/`                         | Airflow 任务日志                         |
| `~/Library/Logs/ControlMyMac/Airflow/maintenance/YYYY-MM-DD/`                   | 清理维护日志                             |
| `~/.controlmymac/python-packages.status`                                        | 依赖安装/验证状态                        |

运行时 `airflow.cfg` 会在启动时重新生成，请勿将 bundle 中的 `conf/airflow.cfg.jinja2` 当作活动配置文件。

## 凭据与日志保留

唯一的 Airflow 管理员为 `controlmymac`，密码会在每次 supervisor 启动前轮换。通过设置页显示或复制密码；不要从日志、状态文件或其他用户读取它。内部 JWT 与网页登录密码无关。

日志保留天数默认是 30。保存正整数设置会立即删除早于保留截止日期的日期目录；启动和跨日时也会执行相同清理。日志清理会跳过符号链接和日志根目录以外的路径。

## 故障排除

```bash
plutil -lint ~/Library/LaunchAgents/com.liuzheng.controlmymac.airflow.plist
plutil -lint ~/Library/LaunchAgents/com.liuzheng.controlmymac.ui.plist
launchctl print gui/$(id -u)/com.liuzheng.controlmymac.airflow
curl --fail http://127.0.0.1:50100
lsof -nP -iTCP:50100 -sTCP:LISTEN
```

正常监听结果只应包含 `127.0.0.1:50100`。依次检查服务状态、依赖状态和当天的 service 日志；若 runtime、依赖、plist 或 API 启动失败，修复根因后运行 `make install`。

## 卸载

```bash
make uninstall
```

该命令删除 `/Applications/ControlMyMac.app` 及两个 LaunchAgent，但保留上述 Airflow 状态、DAG、日志和 Python 包。需要彻底清除这些用户数据时，请先备份所需 DAG 与日志，再手动删除对应用户目录。
