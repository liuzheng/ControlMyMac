import SwiftUI
import AppKit
import Combine
import ControlMyMacCore

@main
struct ControlMyMacApp {
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) {
            application.run()
        }
    }
}

/// AppKit hosts the SwiftUI views without requiring macOS 13's MenuBarExtra
/// or macOS 14's SettingsLink. Keep one shared model and one settings window.
final class AppDelegate: NSObject, NSApplicationDelegate {
    static let settingsWindowIdentifier = NSUserInterfaceItemIdentifier("ControlMyMac.settings")
    private let model = AppModel()
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var settingsWindow: NSWindow?
    private var subscriptions = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item
        item.button?.target = self
        item.button?.action = #selector(togglePopover(_:))
        updateStatusItem()

        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView:
            MenuView(openSettings: { [weak self] in self?.showSettings() })
                .environmentObject(model)
        )

        model.$airflowStatus
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateStatusItem() }
            .store(in: &subscriptions)
        model.$languagePreference
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.settingsWindow?.title = self?.model.localized(.settings) ?? "ControlMyMac"
            }
            .store(in: &subscriptions)
    }

    private func updateStatusItem() {
        let image = model.menuIcon
        image.isTemplate = true
        statusItem?.button?.image = image
        statusItem?.button?.setAccessibilityLabel("ControlMyMac")
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    private func showSettings() {
        popover.performClose(nil)
        if settingsWindow == nil {
            let controller = NSHostingController(rootView: SettingsView().environmentObject(model))
            let window = NSWindow(contentViewController: controller)
            window.identifier = Self.settingsWindowIdentifier
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.title = model.localized(.settings)
            window.setContentSize(NSSize(width: 640, height: 520))
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

/// The foreground app manages Airflow state and user-facing controls.
final class AppModel: ObservableObject {
    @Published var airflowStatus: AirflowServiceStatus
    @Published var airflowCredentials: AirflowSimpleAuthCredentials?
    @Published var airflowPasswordRevealed = false
    @Published var airflowRetentionDays: Int
    @Published var airflowCleanupResult: AirflowCleanupResult?
    @Published var languagePreference: AppLanguage
    @Published var pythonRuntimeStatus: PythonRuntimeStatus = PythonRuntime().status()
    @Published var pythonDependencyStatus = PythonDependencyStatus()
    @Published var message = ""

    private var timer: Timer?
    private let airflowPaths: AirflowPaths
    private let airflowController: AirflowServiceController

    init() {
        languagePreference = AppLanguage.load()
        let paths = AirflowPaths()
        airflowPaths = paths
        airflowController = AirflowServiceController(paths: paths)
        airflowStatus = AirflowServiceStatus(phase: .stopped, paths: paths)
        airflowRetentionDays = AirflowLogSettings.retention().days
        airflowCleanupResult = AirflowCleanupResult.read(from: paths.cleanupStatus)
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    var locale: Locale { languagePreference.locale }

    func setLanguage(_ language: AppLanguage) {
        languagePreference = language
        language.save()
    }

    func localized(_ key: AppTextKey) -> String {
        AppLocalizer.string(key, language: languagePreference)
    }

    func localized(chinese: String, english: String) -> String {
        languagePreference.isChinese ? chinese : english
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
    }

    var serviceOn: Bool { airflowStatus.isRunning }

    var serviceText: String {
        switch airflowStatus.phase {
        case .ready: return localized(.serviceReady)
        case .starting: return localized(.serviceStarting)
        case .failed: return localized(.serviceFailed)
        case .stopped: return localized(.serviceStopped)
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
        case .stopped: return localized(.phaseStopped)
        case .starting: return localized(.phaseStarting)
        case .ready: return localized(.phaseReady)
        case .failed: return localized(.phaseFailed)
        }
    }

    var airflowRecoveryGuidance: String {
        switch airflowStatus.phase {
        case .ready: return localized(.guidanceReady)
        case .starting: return localized(.guidanceStarting)
        case .failed: return localized(.guidanceFailed)
        case .stopped: return localized(.guidanceStopped)
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
                message = result.ok
                    ? localized(chinese: "Airflow 正在启动", english: "Airflow is starting")
                    : localized(chinese: "Airflow 启动失败：\(result.detail)", english: "Airflow failed to start: \(result.detail)")
            case .failure(let error):
                let detail = error.localizedDescription
                AirflowDiagnostic(phase: .failed, message: detail).write(to: airflowPaths.diagnostic)
                message = detail
            }
        } catch {
            message = localized(
                chinese: "Airflow 工作目录准备失败：\(error.localizedDescription)",
                english: "Unable to prepare the Airflow workspace: \(error.localizedDescription)"
            )
        }
        refresh()
    }

    func stopAirflow() {
        let result = airflowController.stop()
        message = result.ok
            ? localized(chinese: "已停止 Airflow", english: "Airflow stopped")
            : localized(chinese: "停止 Airflow 失败：\(result.detail)", english: "Failed to stop Airflow: \(result.detail)")
        refresh()
    }

    func restartAirflow() {
        let result = airflowController.restart()
        message = result.ok
            ? localized(chinese: "已重启 Airflow", english: "Airflow restarted")
            : localized(chinese: "重启 Airflow 失败：\(result.detail)", english: "Failed to restart Airflow: \(result.detail)")
        refresh()
    }

    func copyAirflowPassword() -> String {
        guard airflowStatus.phase == .ready, let credentials = airflowCredentials else {
            return localized(.passwordUnavailable)
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(credentials.password, forType: .string) else {
            return localized(
                chinese: "无法复制 Airflow 密码",
                english: "Unable to copy the Airflow password"
            )
        }
        return localized(.passwordCopied)
    }

    func openAirflow() {
        guard airflowStatus.phase == .ready else {
            message = airflowStatus.detail.isEmpty
                ? localized(chinese: "Airflow 尚未就绪", english: "Airflow is not ready")
                : airflowStatus.detail
            return
        }
        NSWorkspace.shared.open(airflowStatus.endpoint)
    }

    func revealAirflowDAGs() {
        reveal(airflowPaths.dags, missing: localized(chinese: "DAG 目录尚未创建", english: "The DAG directory has not been created"))
    }

    func revealAirflowLogs() {
        reveal(airflowPaths.logRoot, missing: localized(chinese: "Airflow 日志目录尚未创建", english: "The Airflow log directory has not been created"))
    }

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
            message = localized(
                chinese: "日志保留天数必须是正整数",
                english: "Log retention days must be a positive integer"
            )
            return
        }
        airflowCleanupResult = AirflowLogCleaner(paths: airflowPaths).clean(retention: retention)
        message = airflowCleanupResult?.diagnostic ?? localized(
            chinese: "Airflow 日志清理完成",
            english: "Airflow log cleanup completed"
        )
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