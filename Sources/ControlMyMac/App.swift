import SwiftUI
import AppKit
import LocalAuthentication
import ControlMyMacCore

@main
struct ControlMyMacApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuView().environmentObject(model)
        } label: {
            Image(nsImage: model.menuIcon)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView().environmentObject(model)
        }
    }
}

/// Airflow remains independently managed, while phase-one privileged-operation
/// requests are served only by this foreground App process.
final class AppModel: ObservableObject {
    @Published var airflowStatus: AirflowServiceStatus
    @Published var airflowCredentials: AirflowSimpleAuthCredentials?
    @Published var airflowPasswordRevealed = false
    @Published var airflowRetentionDays: Int
    @Published var airflowCleanupResult: AirflowCleanupResult?
    @Published var pythonRuntimeStatus: PythonRuntimeStatus = PythonRuntime().status()
    @Published var pythonDependencyStatus = PythonDependencyStatus()
    @Published var operationRequests: [PrivilegedOperationRequest] = []
    @Published var selectedOperationRequest: PrivilegedOperationRequest?
    @Published var manualHandoff: PrivilegedManualTerminalHandoff?
    @Published var message = ""

    private var autoPromptQueue: [PrivilegedOperationRequest] = []
    private var autoPromptedRequestIDs = Set<PrivilegedOperationRequestID>()
    private var isAutoPromptActive = false

    private var timer: Timer?
    private let airflowPaths: AirflowPaths
    private let airflowController: AirflowServiceController
    private let phaseOneBrokerService: PhaseOneSocketBrokerService

    init() {
        let paths = AirflowPaths()
        airflowPaths = paths
        airflowController = AirflowServiceController(paths: paths)
        phaseOneBrokerService = PhaseOneSocketBrokerService()
        airflowStatus = AirflowServiceStatus(phase: .stopped, paths: paths)
        airflowRetentionDays = AirflowLogSettings.retention().days
        airflowCleanupResult = AirflowCleanupResult.read(from: paths.cleanupStatus)
        phaseOneBrokerService.onRequestCreated = { [weak self] request in
            DispatchQueue.main.async { self?.enqueueAutomaticPrompt(for: request) }
        }
        startPhaseOneBroker()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    deinit { phaseOneBrokerService.stop() }

    private func startPhaseOneBroker() {
        do {
            try phaseOneBrokerService.start()
        } catch {
            message = "阶段一请求服务不可用：\(error.localizedDescription)"
            phaseOneBrokerService.stop()
        }
    }

    private func enqueueAutomaticPrompt(for request: PrivilegedOperationRequest) {
        guard request.state == .pendingAuthorization, autoPromptedRequestIDs.insert(request.id).inserted else { return }
        autoPromptQueue.append(request)
        refresh()
        beginNextAutomaticPrompt()
    }

    private func beginNextAutomaticPrompt() {
        guard !isAutoPromptActive, let request = autoPromptQueue.first else { return }
        isAutoPromptActive = true
        NSApp.activate(ignoringOtherApps: true)
        selectedOperationRequest = request
        let context = LAContext()
        context.evaluatePolicy(
            .deviceOwnerAuthentication,
            localizedReason: "批准 \(request.payload.operationID.rawValue) 请求；认证后仍需确认复制终端命令。"
        ) { [weak self] success, error in
            DispatchQueue.main.async {
                guard let self else { return }
                self.autoPromptQueue.removeFirst()
                self.isAutoPromptActive = false
                defer { self.beginNextAutomaticPrompt() }
                guard success else {
                    self.message = error?.localizedDescription ?? "未完成设备所有者认证；请求保持等待状态。"
                    return
                }
                do {
                    _ = try self.phaseOneBrokerService.approve(request.id, expectedPayloadDigest: request.payloadDigest)
                    self.previewOperationRequest(request.id)
                    self.message = "请求已认证；请核对并确认复制终端命令。"
                } catch {
                    self.message = "认证结果无法用于该请求：\(error.localizedDescription)"
                }
                self.refresh()
            }
        }
    }

    func refresh() {
        airflowStatus = airflowController.status()
        pythonRuntimeStatus = PythonRuntime().status()
        pythonDependencyStatus = PythonDependencyStatus.read()
        if airflowStatus.phase == .ready {
            airflowCredentials = AirflowSimpleAuthCredentials.read(from: airflowPaths.simpleAuthPasswords)
        } else {
            airflowCredentials = nil
            airflowPasswordRevealed = false
        }
        airflowCleanupResult = AirflowCleanupResult.read(from: airflowPaths.cleanupStatus) ?? airflowCleanupResult
        operationRequests = (try? phaseOneBrokerService.requests()) ?? operationRequests
    }

    func approveOperationRequest(_ id: PrivilegedOperationRequestID) {
        guard let request = operationRequests.first(where: { $0.id == id }), request.state == .pendingAuthorization else {
            message = "请求已失效或不再需要批准"
            return
        }
        let context = LAContext()
        context.evaluatePolicy(
            .deviceOwnerAuthentication,
            localizedReason: "批准 \(request.payload.operationID.rawValue) 请求；命令仅会在您确认复制后交给 Terminal。"
        ) { [weak self] success, error in
            DispatchQueue.main.async {
                guard let self else { return }
                guard success else {
                    self.message = error?.localizedDescription ?? "未完成设备所有者认证"
                    return
                }
                do {
                    _ = try self.phaseOneBrokerService.approve(id, expectedPayloadDigest: request.payloadDigest)
                    self.message = "请求已批准；请查看并确认终端命令。"
                } catch {
                    self.message = "无法批准请求：\(error.localizedDescription)"
                }
                self.refresh()
            }
        }
    }

    func previewOperationRequest(_ id: PrivilegedOperationRequestID) {
        do {
            let request = try phaseOneBrokerService.broker.status(id)
            guard request.state == .authorized else {
                message = "请求尚未获批准，不能生成终端命令"
                return
            }
            selectedOperationRequest = request
            manualHandoff = try phaseOneBrokerService.broker.registry.manualTerminalHandoff(
                for: request.payload,
                serviceResolver: MacOSNetworkServiceResolver()
            )
            message = "请核对完整命令；它尚未执行"
        } catch {
            selectedOperationRequest = nil
            manualHandoff = nil
            message = "无法生成终端命令：\(error.localizedDescription)"
        }
    }

    func copyManualHandoff() {
        guard let request = selectedOperationRequest, let handoff = manualHandoff, request.state == .authorized else {
            message = "没有可复制的已批准终端命令"
            return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(handoff.command, forType: .string) else {
            message = "无法复制终端命令"
            return
        }
        do {
            _ = try phaseOneBrokerService.recordManualHandoff(request.id)
            message = "命令已复制；请在 Terminal 粘贴并使用 sudo 密码执行。"
            manualHandoff = nil
            selectedOperationRequest = nil
        } catch {
            message = "命令已复制，但无法记录手动交接：\(error.localizedDescription)"
        }
        refresh()
    }

    func cancelOperationRequest(_ id: PrivilegedOperationRequestID) {
        do {
            _ = try phaseOneBrokerService.broker.cancel(id)
            message = "请求已取消"
        } catch {
            message = "无法取消请求：\(error.localizedDescription)"
        }
        refresh()
    }

    var serviceOn: Bool { airflowStatus.isRunning }

    var serviceText: String {
        switch airflowStatus.phase {
        case .ready: return "Airflow 正在运行"
        case .starting: return "Airflow 正在启动…"
        case .failed: return "Airflow 启动失败"
        case .stopped: return "Airflow 已停止"
        }
    }

    var serviceColor: Color {
        switch airflowStatus.phase {
        case .ready: return .green
        case .starting: return .yellow
        case .failed: return .red
        case .stopped: return .secondary
        }
    }

    var menuIcon: NSImage {
        let symbol: String
        switch airflowStatus.phase {
        case .ready: symbol = "wind"
        case .starting: symbol = "wind.snow"
        case .failed: symbol = "exclamationmark.triangle"
        case .stopped: symbol = "wind.snow"
        }
        return NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage(size: .zero)
    }

    var airflowPhaseText: String {
        switch airflowStatus.phase {
        case .stopped: return "已停止"
        case .starting: return "正在启动"
        case .ready: return "已就绪"
        case .failed: return "启动失败"
        }
    }

    var airflowRecoveryGuidance: String {
        switch airflowStatus.phase {
        case .ready: return "本地服务仅监听 127.0.0.1:50100。"
        case .starting: return "正在迁移元数据并启动组件；请稍候刷新。"
        case .failed: return "检查 Airflow 服务日志，确认 Python 3.14、apache-airflow==3.3.2 和端口 50100 可用。"
        case .stopped: return "点击启动以运行本地 Airflow 服务。"
        }
    }

    func setServiceEnabled(_ enabled: Bool) {
        enabled ? startAirflow() : stopAirflow()
    }

    func startAirflow() {
        do {
            try AirflowWorkspace(paths: airflowPaths).provision()
            try AirflowLogSettings.save(days: airflowRetentionDays, paths: airflowPaths)
            switch AirflowRuntimeValidator().validate() {
            case .success:
                let result = airflowController.start()
                message = result.ok ? "Airflow 正在启动" : "Airflow 启动失败：\(result.detail)"
            case .failure(let error):
                let detail = error.localizedDescription
                AirflowDiagnostic(phase: .failed, message: detail).write(to: airflowPaths.diagnostic)
                message = detail
            }
        } catch {
            message = "Airflow 工作目录准备失败：\(error.localizedDescription)"
        }
        refresh()
    }

    func stopAirflow() {
        let result = airflowController.stop()
        message = result.ok ? "已停止 Airflow" : "停止 Airflow 失败：\(result.detail)"
        refresh()
    }

    func restartAirflow() {
        let result = airflowController.restart()
        message = result.ok ? "已重启 Airflow" : "重启 Airflow 失败：\(result.detail)"
        refresh()
    }

    func copyAirflowPassword() -> String {
        guard airflowStatus.phase == .ready, let credentials = airflowCredentials else {
            return "Airflow 登录凭据尚不可用"
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(credentials.password, forType: .string) else {
            return "无法复制 Airflow 密码"
        }
        return "Airflow 密码已复制到剪贴板"
    }

    func openAirflow() {
        guard airflowStatus.phase == .ready else {
            message = airflowStatus.detail.isEmpty ? "Airflow 尚未就绪" : airflowStatus.detail
            return
        }
        NSWorkspace.shared.open(airflowStatus.endpoint)
    }

    func revealAirflowDAGs() { reveal(airflowPaths.dags, missing: "DAG 目录尚未创建") }
    func revealAirflowLogs() { reveal(airflowPaths.logRoot, missing: "Airflow 日志目录尚未创建") }

    func saveAirflowRetention() {
        do {
            try AirflowLogSettings.save(days: airflowRetentionDays, paths: airflowPaths)
            runAirflowLogCleanup()
        } catch {
            message = error.localizedDescription
        }
    }

    func runAirflowLogCleanup() {
        guard let retention = AirflowLogRetention(days: airflowRetentionDays) else {
            message = "日志保留天数必须是正整数"
            return
        }
        airflowCleanupResult = AirflowLogCleaner(paths: airflowPaths).clean(retention: retention)
        message = airflowCleanupResult?.diagnostic ?? "Airflow 日志清理完成"
        refresh()
    }

    private func reveal(_ url: URL, missing: String) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            message = "\(missing)：\(url.path)"
            return
        }
        NSWorkspace.shared.open(url)
    }
}