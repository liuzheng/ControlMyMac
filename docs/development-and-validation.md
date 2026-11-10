# 开发与验证

ControlMyMac 是 macOS 12+ Swift Package，最低工具链为 Swift 5.7（Xcode 14），并在 App bundle 中携带 Python 3.14.7 runtime。以下命令均应从仓库根目录以普通用户运行。

菜单栏使用 AppKit 的 `NSStatusItem` / `NSPopover`，设置页使用独立的 `NSWindow`，均由 `NSHostingController` 承载 SwiftUI 内容。不要直接使用 macOS 13+ 的 `MenuBarExtra`、`Text.monospaced()` 或 macOS 14+ 的 `SettingsLink`、新版 `onChange` 重载，以免破坏 Monterey 兼容性。

## 构建

```bash
swift build            # Debug 构建
swift build -c release # Release 构建
make build             # 等同于 release Swift 构建，并拒绝 root 执行
make bundle            # 生成 build/ControlMyMac.app（含 runtime、图标和 ad-hoc 签名）
```

`make bundle` 需要仓库根目录中的 `python-3.14.7-macos11.pkg` 以及 macOS/Xcode 工具。它会清空并重建 `build/ControlMyMac.app`，但不会安装到 `/Applications`。安装请使用 `make install`；该命令会重新 bundle 后调用需要 `sudo` 的安装脚本。

## 自动化测试

项目没有 `make test` target。运行以下两个测试入口：

```bash
swift test
python3 Tests/airflow_supervisor_tests.py
```

Swift 测试覆盖 Airflow 工作区路径/配置、服务阶段判定、`launchctl` 命令构造、日志保留与符号链接安全、SimpleAuth 凭据校验和 Python runtime 验证。Python 测试仅使用标准库，覆盖 supervisor 的配置、凭据轮换、日志清理与运行环境行为。

Swift runtime 测试只有在 `build/ControlMyMac.app` 已存在时才会校验内嵌 runtime 版本。要覆盖该断言，请运行：

```bash
make bundle
swift test
```

## 人工冒烟验证

在隔离 macOS 账户中安装后，确认两个 LaunchAgent、Airflow 端点和 listener：

```bash
plutil -lint ~/Library/LaunchAgents/com.liuzheng.controlmymac.airflow.plist
plutil -lint ~/Library/LaunchAgents/com.liuzheng.controlmymac.ui.plist
launchctl print gui/$(id -u)/com.liuzheng.controlmymac.airflow
curl --fail http://127.0.0.1:50100
lsof -nP -iTCP:50100 -sTCP:LISTEN
```

最后一条命令应只显示 `127.0.0.1:50100`。还应在设置页确认：runtime 和依赖状态可见、服务就绪后可打开 Airflow、凭据仅在就绪时可显示/复制、保存日志保留天数会立即产生清理结果。

在 macOS 12 上还需检查：点击菜单栏图标可打开/关闭弹窗；点击弹窗外会关闭弹窗；“设置”会激活同一个设置窗口；关闭设置后菜单栏应用仍运行，重新打开设置正常；切换语言后两个界面及设置窗口标题更新；复制密码的反馈在设置窗口重新激活时清除。

## 修改边界

- `Sources/ControlMyMacCore/` 包含路径、状态、服务控制、凭据读取和日志清理等可测试逻辑。
- `Sources/ControlMyMac/` 包含 SwiftUI 菜单栏和设置页。`AppModel` 是跨窗口共享的服务状态；短暂设置页反馈应使用视图本地状态。
- `Resources/airflow-supervisor.py` 管理 Airflow 子进程、启动迁移、凭据轮换和运行期清理；修改后应运行 Python 测试。
- App bundle 中的 `conf/` 为资源副本；实际 `airflow.cfg` 由安装脚本和 supervisor 在用户 Airflow 目录生成。

涉及安装脚本、LaunchAgent、运行时或依赖的改动应在非生产 macOS 账户中先完整执行 `make install` 和上述冒烟检查。
