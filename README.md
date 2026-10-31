<img src="Resources/source-icon.webp" width="96" alt="ControlMyMac 图标">

# ControlMyMac

ControlMyMac 是 macOS 14+ 的菜单栏应用，用于管理当前登录用户的本地 Apache Airflow 服务。它只在 `http://127.0.0.1:50100` 提供服务，绝不绑定非 loopback 网络接口。应用仅在 LaunchAgent 已加载且本地 API 可访问时显示“已就绪”。

## 组成

```text
ControlMyMac.app     /Applications 中的菜单栏应用；显示状态并提供 Airflow 控制、凭据与日志管理
Airflow LaunchAgent  ~/Library/LaunchAgents/com.liuzheng.controlmymac.airflow.plist
UI LaunchAgent       ~/Library/LaunchAgents/com.liuzheng.controlmymac.ui.plist；登录时启动菜单栏应用
```

Airflow 是独立受管服务。阶段一期间，菜单栏 App 还会在自身运行时托管一个用户私有 Unix Socket，用于接收 allow-listed 的本地操作请求；退出 App 会关闭该 socket，且不会启动独立 Broker、LaunchAgent 或 root Helper。旧版网卡 Rule、蓝牙 Focus、Wi‑Fi、统一监听对象及旧 `config.json` 的监听字段均已移除且不会执行。

## 构建与安装

构建必须以当前用户身份运行；不要使用 `sudo make`。安装与卸载会在需要时请求管理员权限。

```bash
make           # 生成 release bundle 并安装到 /Applications
make build     # 仅执行 swift build -c release
make bundle    # 构建 release 可执行文件、内嵌 Python runtime 并生成 build/ControlMyMac.app
make install   # 重新生成 bundle 后安装（不是安装旧 bundle）
make uninstall # 卸载 App 和两个 LaunchAgent；保留用户 Airflow 数据
make clean     # 删除 .build 和 build 构建产物
```

`make bundle` 使用仓库中的 `python-3.14.7-macos11.pkg`，将 Python 3.14.7 内嵌至 App，并进行 ad-hoc 签名；它不是已公证的分发包。安装时会下载并验证 `apache-airflow==3.3.2`，默认使用 Aliyun PyPI 镜像；可通过 `PIP_INDEX_URL` 覆盖索引。例如：

```bash
PIP_INDEX_URL=https://pypi.org/simple make install
```

网络或依赖安装失败时，App 仍可能完成安装，但 Airflow 不可用。请检查 `~/.controlmymac/python-packages.status` 与下文的服务诊断文件，然后修正网络/索引并重新运行 `make install`。

## 使用与服务生命周期

菜单栏提供启停、重启、打开 Airflow、打开日志目录、设置和退出。设置页提供同样的服务操作、Python runtime/依赖状态、DAG 与日志目录、日志保留期，以及就绪状态下的登录凭据显示/复制。

每次 Airflow supervisor 启动时会：生成用户专属配置、清理过期日志、验证 runtime 与 Airflow 版本、执行 `airflow db migrate`，然后启动 scheduler、dag-processor、triggerer 和仅监听 `127.0.0.1:50100` 的 API server。API 在 30 秒内返回非 5xx HTTP 响应后才被标记为就绪；菜单栏状态每 3 秒刷新一次。

> **当前停止后的恢复方式**：设置页的“停止”会通过 `launchctl bootout` 卸载 Airflow job；现有“启动”实现不会重新 bootstrap 已卸载的 job。若停止后无法在设置页启动，请运行 `make install` 重新注册并加载 LaunchAgent。

## 数据、日志与权限

安装、更新、服务重启与卸载都不会覆盖或删除用户 DAG、Airflow 状态、日志或用户级 Python 包。

| 位置 | 用途 |
|---|---|
| `~/Library/Application Support/ControlMyMac/dags/` | 用户 DAG 的唯一受支持目录 |
| `~/Library/Application Support/ControlMyMac/airflow/airflow.cfg` | 当前用户的自动生成 Airflow 配置（不编辑 App bundle 中的模板） |
| `~/Library/Application Support/ControlMyMac/airflow/service-status.json` | 服务阶段和故障诊断 |
| `~/Library/Application Support/ControlMyMac/airflow/simple-auth-passwords.json` | SimpleAuth 凭据，权限为 0600 |
| `~/Library/Application Support/ControlMyMac/airflow/api-auth-jwt-secret.json` | Airflow 内部 execution API JWT 密钥，权限为 0600 |
| `~/Library/Application Support/ControlMyMac/airflow/log-retention.json` | 日志保留设置，权限为 0600 |
| `~/Library/Application Support/ControlMyMac/airflow/cleanup-status.json` | 最近一次日志清理结果 |
| `~/Library/Logs/ControlMyMac/Airflow/{service,tasks,maintenance}/YYYY-MM-DD/` | 服务、任务及维护日志 |
| `~/.controlmymac/python-packages/` | 内嵌 Python 使用的 Airflow 依赖 |
| `~/.controlmymac/python-packages.status` | 依赖安装/验证状态 |

日志保留期默认 30 天，必须为正整数。设置页保存后会立即清理；supervisor 也会在启动和日期变化时清理。只有严格早于“当前日期 − 保留天数”的日期目录会被删除。

## 登录凭据

Airflow 的唯一 SimpleAuth 管理员账号是 `controlmymac`，角色为 `admin`。密码在每次服务启动或重启时重新生成，不是安装时固定的密码。它保存在用户专属的 0600 文件中，不会写入服务状态或日志；设置页仅在服务就绪时允许显示、隐藏或复制。复制密码意味着允许本机其他可读取剪贴板的应用获取该密码。

`api-auth-jwt-secret.json` 是 Airflow 进程间认证所需的独立内部密钥，不是网页登录密码，也不应手动修改。

## DAG

DAG 需由用户自行放入 `~/Library/Application Support/ControlMyMac/dags/`。仓库中的 `dags_demo/wired_ethernet_inserted.py` 是可选示例，不会随安装自动复制；它不是已移除的内置网卡监听功能。详情见 [DAG 指南](docs/dags.md)。

## 阶段一本地操作请求

阶段一允许用户 DAG 在 ControlMyMac App 保持运行时，通过本地 Unix Socket 提交已注册的操作请求。App 在 Settings 中显示请求、经过 Touch ID 或系统密码认证后预览固定命令，并仅在用户再次确认时复制到剪贴板。它不会创建 `/tmp` 脚本、启动 Terminal、调用 `sudo`、自动执行网络配置或启动 root Helper。

DAG 收到 `manual_execution_required` 表示命令已审核并复制，**不表示配置已经成功**。用户仍需自行在 Terminal 粘贴命令，并由 Terminal 的 `sudo` 密码完成最终系统授权。示例部署与排查见 [DAG 指南](docs/dags.md)。

## 验证与恢复

安装后可在开发或隔离测试账户中执行：

```bash
plutil -lint ~/Library/LaunchAgents/com.liuzheng.controlmymac.airflow.plist
plutil -lint ~/Library/LaunchAgents/com.liuzheng.controlmymac.ui.plist
launchctl print gui/$(id -u)/com.liuzheng.controlmymac.airflow
curl --fail http://127.0.0.1:50100
lsof -nP -iTCP:50100 -sTCP:LISTEN
```

最后一项应仅显示 `127.0.0.1:50100`。若服务未就绪，请依次检查 `service-status.json`、`python-packages.status`、当天的 `service/stdout.log` 与 `service/stderr.log`，修正问题后运行 `make install`。更多运维步骤见 [运维指南](docs/operations.md)。

开发验证命令与覆盖范围见 [开发与验证](docs/development-and-validation.md)。

## 应用图标

图标源图为 `Resources/source-icon.webp`；`make bundle` 使用 `Tools/make-icon.swift` 生成应用 `.icns`。
