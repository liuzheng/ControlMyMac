# CLAUDE.md

## 项目概要

ControlMyMac 是 macOS 14+ 菜单栏工具，管理登录用户的本地 Apache Airflow 服务。Airflow LaunchAgent `com.liuzheng.controlmymac.airflow` 是唯一受管服务；应用状态仅取决于 `AirflowServiceStatus.phase`。

## 常用命令

```bash
make                 # bundle + install
make build           # swift build -c release
make bundle          # 生成包含 Python 3.14 runtime 的 .app
make install         # bundle + sudo scripts/install.sh
make uninstall       # 移除 App/LaunchAgent，保留 Airflow 用户数据
swift test
```

不要用 root 运行 `make` 或 `swift build`，否则 `.build` 和 `build` 会成为 root 所有。直接运行 `sudo bash scripts/install.sh` 前必须先生成 bundle。

## 架构

- `ControlMyMacCore/AirflowService.swift` 定义 Airflow 的路径、工作目录、私有 SimpleAuth 凭据、日志保留、运行时验证、服务状态和 launchd 控制器。
- `ControlMyMac` 是唯一可执行 target；其菜单栏和设置 UI 只显示并控制 Airflow。
- `Resources/airflow-supervisor.py` 使用 App 内置 Python 启动 Airflow 公共 CLI 组件，仅绑定 `127.0.0.1:50100`。
- `scripts/install.sh` 安装 App、Airflow LaunchAgent 和 UI LaunchAgent；为升级兼容会清理旧 root daemon、listener helper 与其 plist，但不会安装新的监听服务。
- 用户 Airflow 数据位于 `~/Library/Application Support/ControlMyMac/{dags,airflow}/`；日志在 `~/Library/Logs/ControlMyMac/Airflow/`；依赖在 `~/.controlmymac/python-packages/`。安装和卸载都不得删除这些用户数据。

## Python runtime 和依赖

`Tools/prepare-python-runtime.sh` 从固定 Python 3.14.7 pkg 准备 framework 并生成哈希 manifest。`PythonRuntime` 必须验证 manifest、架构、文件哈希和解释器；验证失败绝不能回退到系统 Python。安装脚本以目标用户身份将 `apache-airflow==3.3.2` 安装到用户包目录。

## OpenSpec

变更计划位于 `openspec/changes/<name>/`。实现前阅读该变更的 proposal、specs、design 和 tasks；实施期间只在行为完整并已验证后勾选任务。