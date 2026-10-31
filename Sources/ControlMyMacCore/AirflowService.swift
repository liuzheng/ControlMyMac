import Foundation

public enum AirflowServicePhase: String, Codable, Hashable {
    case stopped
    case starting
    case ready
    case failed
}

public struct AirflowPaths: Hashable {
    public static let label = "com.liuzheng.controlmymac.airflow"
    public static let endpoint = URL(string: "http://127.0.0.1:50100")!
    public static let port = 50100

    public let home: URL
    public let applicationSupport: URL

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.home = home.standardizedFileURL
        applicationSupport = home.appendingPathComponent("Library/Application Support/ControlMyMac", isDirectory: true)
    }

    public var dags: URL { applicationSupport.appendingPathComponent("dags", isDirectory: true) }
    public var airflowHome: URL { applicationSupport.appendingPathComponent("airflow", isDirectory: true) }
    public var runtimeConfig: URL { airflowHome.appendingPathComponent("airflow.cfg") }
    public var diagnostic: URL { airflowHome.appendingPathComponent("service-status.json") }
    public var simpleAuthPasswords: URL { airflowHome.appendingPathComponent("simple-auth-passwords.json") }
    public var logRetention: URL { airflowHome.appendingPathComponent("log-retention.json") }
    public var cleanupStatus: URL { airflowHome.appendingPathComponent("cleanup-status.json") }
    public var logRoot: URL { home.appendingPathComponent("Library/Logs/ControlMyMac/Airflow", isDirectory: true) }
    public func logDirectory(category: AirflowLogCategory, date: Date = Date(), calendar: Calendar = .current) -> URL {
        logRoot.appendingPathComponent(category.rawValue, isDirectory: true)
            .appendingPathComponent(Self.dateFormatter.string(from: date), isDirectory: true)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = .current
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

public enum AirflowLogCategory: String, CaseIterable, Hashable {
    case service
    case tasks
    case maintenance
}

public struct AirflowWorkspace {
    public static let simpleAuthUsername = "controlmymac"
    public let paths: AirflowPaths
    public init(paths: AirflowPaths = AirflowPaths()) { self.paths = paths }

    public func provision(date: Date = Date()) throws {
        let fileManager = FileManager.default
        for directory in [paths.dags, paths.airflowHome, paths.logRoot] + AirflowLogCategory.allCases.map({ paths.logDirectory(category: $0, date: date) }) {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
        }
        try runtimeConfiguration(date: date).write(to: paths.runtimeConfig, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: paths.runtimeConfig.path)
    }

    /// This configuration is deliberately generated rather than taken from the bundle so every path is
    /// absolute, owned by the logged-in user, and remains valid when their home directory differs.
    public func runtimeConfiguration(date: Date = Date()) -> String {
        let taskLog = paths.logDirectory(category: .tasks, date: date).path
        return """
        [core]
        dags_folder = \(paths.dags.path)
        load_examples = False
        auth_manager = airflow.api_fastapi.auth.managers.simple.simple_auth_manager.SimpleAuthManager
        simple_auth_manager_users = \(Self.simpleAuthUsername):admin
        simple_auth_manager_all_admins = False
        simple_auth_manager_passwords_file = \(paths.simpleAuthPasswords.path)
        execution_api_server_url = \(AirflowPaths.endpoint.absoluteString)/execution/

        [database]
        sql_alchemy_conn = sqlite:///\(paths.airflowHome.appendingPathComponent("airflow.db").path)

        [logging]
        base_log_folder = \(taskLog)
        remote_logging = False
        """
    }
}

public struct AirflowDiagnostic: Codable, Hashable {
    public var phase: AirflowServicePhase
    public var message: String
    public var updatedAt: Date

    public init(phase: AirflowServicePhase, message: String, updatedAt: Date = Date()) {
        self.phase = phase
        self.message = message
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey { case phase, message, updatedAt }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        phase = try values.decode(AirflowServicePhase.self, forKey: .phase)
        message = try values.decode(String.self, forKey: .message)
        if let timestamp = try? values.decode(String.self, forKey: .updatedAt) {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            updatedAt = formatter.date(from: timestamp) ?? Date()
        } else {
            updatedAt = Date()
        }
    }

    public static func read(from url: URL) -> AirflowDiagnostic? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Self.self, from: data)
    }

    public func write(to url: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(self) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

public struct AirflowSimpleAuthCredentials: Hashable {
    public static let username = AirflowWorkspace.simpleAuthUsername
    public let password: String
    public var userName: String { Self.username }

    public static func read(from url: URL) -> AirflowSimpleAuthCredentials? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let permissions = attributes[.posixPermissions] as? NSNumber,
              permissions.intValue & 0o077 == 0,
              let data = try? Data(contentsOf: url),
              let values = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(values.keys) == Set([username]),
              let password = values[username] as? String,
              !password.isEmpty else { return nil }
        return AirflowSimpleAuthCredentials(password: password)
    }
}

public enum AirflowRuntimeValidationError: LocalizedError, Equatable {
    case runtime(String)
    case dependency(String)

    public var errorDescription: String? {
        switch self {
        case .runtime(let message): return "Airflow 无法启动：Python runtime 无效：\(message)"
        case .dependency(let message): return "Airflow 无法启动：\(message)"
        }
    }
}

public struct AirflowRuntimeValidator {
    public let runtime: PythonRuntime
    public let packageDirectory: URL
    private let versionReader: (URL, URL) -> ProcResult

    public init(runtime: PythonRuntime = PythonRuntime(), packageDirectory: URL = PythonRuntime.userPackagesURL,
                versionReader: @escaping (URL, URL) -> ProcResult = AirflowRuntimeValidator.defaultVersionReader) {
        self.runtime = runtime
        self.packageDirectory = packageDirectory
        self.versionReader = versionReader
    }

    public func validate() -> Result<Void, AirflowRuntimeValidationError> {
        guard case .success(let validated) = runtime.validate() else {
            return .failure(.runtime(runtime.status().lastError))
        }
        guard FileManager.default.fileExists(atPath: packageDirectory.path) else {
            return .failure(.dependency("未安装 apache-airflow==3.3.2（\(packageDirectory.path)）"))
        }
        let result = versionReader(validated.executable, packageDirectory)
        guard result.ok else {
            return .failure(.dependency("无法验证 apache-airflow==3.3.2：\(result.detail)"))
        }
        let version = result.out.trimmingCharacters(in: .whitespacesAndNewlines)
        guard version == "3.3.2" else {
            return .failure(.dependency("需要 apache-airflow==3.3.2，当前为 \(version.isEmpty ? "未安装" : version)"))
        }
        return .success(())
    }

    public static func defaultVersionReader(executable: URL, packageDirectory: URL) -> ProcResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = ["-s", "-c", "import airflow; print(airflow.__version__)"]
        var environment = ["PYTHONHOME": executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().path,
                           "PYTHONNOUSERSITE": "1", "PYTHONPATH": packageDirectory.path,
                           "PATH": "/usr/bin:/bin"]
        environment["LANG"] = "C"
        process.environment = environment
        let output = Pipe(), error = Pipe()
        process.standardOutput = output
        process.standardError = error
        do { try process.run() } catch {
            return ProcResult(status: -1, out: "", err: error.localizedDescription)
        }
        let out = output.fileHandleForReading.readDataToEndOfFile()
        let err = error.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return ProcResult(status: process.terminationStatus,
                          out: String(data: out, encoding: .utf8) ?? "",
                          err: String(data: err, encoding: .utf8) ?? "")
    }
}

public struct AirflowServiceStatus: Hashable {
    /// Airflow is ControlMyMac's only managed service, so only a ready Airflow
    /// endpoint is considered running by the application UI.
    public var isRunning: Bool { phase == .ready }

    public var phase: AirflowServicePhase
    public var detail: String
    public var endpoint: URL
    public var paths: AirflowPaths
    public var serviceLog: URL
    public var taskLog: URL
    public var maintenanceLog: URL

    public init(phase: AirflowServicePhase, detail: String = "", paths: AirflowPaths, date: Date = Date()) {
        self.phase = phase
        self.detail = detail
        endpoint = AirflowPaths.endpoint
        self.paths = paths
        serviceLog = paths.logDirectory(category: .service, date: date)
        taskLog = paths.logDirectory(category: .tasks, date: date)
        maintenanceLog = paths.logDirectory(category: .maintenance, date: date)
    }
}

public final class AirflowServiceController {
    public typealias CommandRunner = (String, [String]) -> ProcResult
    public typealias ReadinessProbe = () -> Bool
    public let paths: AirflowPaths
    public let uid: uid_t
    private let command: CommandRunner
    private let readinessProbe: ReadinessProbe

    public init(paths: AirflowPaths = AirflowPaths(), uid: uid_t = getuid(),
                command: @escaping CommandRunner = run, readinessProbe: @escaping ReadinessProbe = AirflowReadinessProbe().isReady) {
        self.paths = paths
        self.uid = uid
        self.command = command
        self.readinessProbe = readinessProbe
    }

    public var domain: String { "gui/\(uid)" }
    public var job: String { "\(domain)/\(AirflowPaths.label)" }
    public var launchAgent: URL { paths.home.appendingPathComponent("Library/LaunchAgents/\(AirflowPaths.label).plist") }

    public func status(date: Date = Date()) -> AirflowServiceStatus {
        let printed = command("/bin/launchctl", ["print", job])
        let diagnostic = AirflowDiagnostic.read(from: paths.diagnostic)
        guard printed.ok else {
            if let diagnostic, diagnostic.phase == .failed {
                return AirflowServiceStatus(phase: .failed, detail: diagnostic.message, paths: paths, date: date)
            }
            return AirflowServiceStatus(phase: .stopped, detail: diagnostic?.message ?? "服务未加载", paths: paths, date: date)
        }
        if readinessProbe() {
            return AirflowServiceStatus(phase: .ready, detail: "本地 Airflow 已就绪", paths: paths, date: date)
        }
        let exit = Self.lastExit(in: printed.out)
        if let exit, exit != 0 {
            return AirflowServiceStatus(phase: .failed, detail: diagnostic?.message ?? "Airflow 进程退出（\(exit)）；请查看 \(paths.logRoot.path)", paths: paths, date: date)
        }
        return AirflowServiceStatus(phase: .starting, detail: diagnostic?.message ?? "Airflow 正在初始化…", paths: paths, date: date)
    }

    @discardableResult public func start() -> ProcResult {
        let result = command("/bin/launchctl", ["enable", job])
        guard result.ok else { return result }
        let kicked = command("/bin/launchctl", ["kickstart", "-k", job])
        if !kicked.ok { AirflowDiagnostic(phase: .failed, message: kicked.detail).write(to: paths.diagnostic) }
        return kicked
    }

    @discardableResult public func stop() -> ProcResult {
        let result = command("/bin/launchctl", ["bootout", job])
        if !result.ok { AirflowDiagnostic(phase: .failed, message: result.detail).write(to: paths.diagnostic) }
        return result
    }

    @discardableResult public func restart() -> ProcResult {
        let result = command("/bin/launchctl", ["kickstart", "-k", job])
        if !result.ok { AirflowDiagnostic(phase: .failed, message: result.detail).write(to: paths.diagnostic) }
        return result
    }

    private static func lastExit(in text: String) -> Int? {
        let pattern = #"last exit code = ([0-9]+)"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return Int(text[range])
    }
}

public struct AirflowReadinessProbe {
    public let endpoint: URL
    public let timeout: TimeInterval
    public init(endpoint: URL = AirflowPaths.endpoint, timeout: TimeInterval = 1) {
        self.endpoint = endpoint
        self.timeout = timeout
    }

    public func isReady() -> Bool {
        guard endpoint.host == "127.0.0.1", endpoint.port == AirflowPaths.port else { return false }
        var request = URLRequest(url: endpoint)
        request.timeoutInterval = timeout
        let semaphore = DispatchSemaphore(value: 0)
        var reachable = false
        URLSession.shared.dataTask(with: request) { _, response, _ in
            if let response = response as? HTTPURLResponse, (200..<500).contains(response.statusCode) {
                reachable = true
            }
            semaphore.signal()
        }.resume()
        _ = semaphore.wait(timeout: .now() + timeout)
        return reachable
    }
}

public struct AirflowLogRetention: Hashable {
    public static let defaultDays = 30
    public let days: Int
    public init?(days: Int) {
        guard days > 0 else { return nil }
        self.days = days
    }
}

public enum AirflowLogSettings {
    private struct PersistedRetention: Codable { let days: Int }
    public static let retentionDaysKey = "airflow.log-retention-days"
    public static func retention(defaults: UserDefaults = .standard) -> AirflowLogRetention {
        let stored = defaults.object(forKey: retentionDaysKey) as? Int
        return AirflowLogRetention(days: stored ?? AirflowLogRetention.defaultDays) ?? AirflowLogRetention(days: AirflowLogRetention.defaultDays)!
    }
    public static func save(days: Int, paths: AirflowPaths? = nil, defaults: UserDefaults = .standard) throws {
        guard AirflowLogRetention(days: days) != nil else {
            throw NSError(domain: "ControlMyMac.Airflow", code: 1, userInfo: [NSLocalizedDescriptionKey: "日志保留天数必须是正整数"])
        }
        defaults.set(days, forKey: retentionDaysKey)
        if let paths {
            try FileManager.default.createDirectory(at: paths.airflowHome, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let data = try JSONEncoder().encode(PersistedRetention(days: days))
            try data.write(to: paths.logRetention, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: paths.logRetention.path)
        }
    }
}

public struct AirflowCleanupResult: Hashable, Codable {
    public let deletedItems: Int
    public let diagnostic: String

    public static func read(from url: URL) -> AirflowCleanupResult? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }

    public func write(to url: URL) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        try? data.write(to: url, options: .atomic)
    }
}

public struct AirflowLogCleaner {
    public let paths: AirflowPaths
    public init(paths: AirflowPaths = AirflowPaths()) { self.paths = paths }

    public func clean(retention: AirflowLogRetention, now: Date = Date(), calendar: Calendar = .current) -> AirflowCleanupResult {
        let fileManager = FileManager.default
        var deleted = 0
        var problems: [String] = []
        let root = paths.logRoot.resolvingSymlinksInPath().standardizedFileURL
        guard isDescendant(root, of: root), fileManager.fileExists(atPath: root.path) else {
            return record(AirflowCleanupResult(deletedItems: 0, diagnostic: "日志根目录不存在：\(root.path)"), now: now, calendar: calendar)
        }
        guard let cutoff = calendar.date(byAdding: .day, value: -retention.days, to: calendar.startOfDay(for: now)) else {
            return record(AirflowCleanupResult(deletedItems: 0, diagnostic: "无法计算日志清理日期"), now: now, calendar: calendar)
        }
        for category in AirflowLogCategory.allCases {
            let categoryURL = root.appendingPathComponent(category.rawValue, isDirectory: true)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: categoryURL.path, isDirectory: &isDirectory) else { continue }
            guard isDirectory.boolValue, !isSymbolicLink(categoryURL) else {
                problems.append("跳过不安全日志类别：\(categoryURL.path)")
                continue
            }
            guard let entries = try? fileManager.contentsOfDirectory(at: categoryURL, includingPropertiesForKeys: [.isSymbolicLinkKey], options: []) else {
                problems.append("无法读取：\(categoryURL.path)")
                continue
            }
            for entry in entries {
                guard entry.lastPathComponent.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else { continue }
                let resolved = entry.resolvingSymlinksInPath().standardizedFileURL
                guard isDescendant(resolved, of: root), !isSymbolicLink(entry) else {
                    problems.append("跳过根目录外或符号链接：\(entry.path)")
                    continue
                }
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.calendar = calendar
                formatter.timeZone = calendar.timeZone
                formatter.dateFormat = "yyyy-MM-dd"
                guard let entryDate = formatter.date(from: entry.lastPathComponent), entryDate < cutoff else { continue }
                do {
                    try fileManager.removeItem(at: entry)
                    deleted += 1
                } catch {
                    problems.append("无法删除 \(entry.path)：\(error.localizedDescription)")
                }
            }
        }
        let message = problems.isEmpty ? "已删除 \(deleted) 个过期日志目录" : problems.joined(separator: "；")
        let result = AirflowCleanupResult(deletedItems: deleted, diagnostic: message)
        result.write(to: paths.cleanupStatus)
        return record(result, now: now, calendar: calendar)
    }

    private func record(_ result: AirflowCleanupResult, now: Date, calendar: Calendar) -> AirflowCleanupResult {
        result.write(to: paths.cleanupStatus)
        let directory = paths.logDirectory(category: .maintenance, date: now, calendar: calendar)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let line = "\(ISO8601DateFormatter().string(from: now)) \(result.diagnostic)\n"
        let url = directory.appendingPathComponent("cleanup.log")
        if let handle = FileHandle(forWritingAtPath: url.path) {
            defer { try? handle.close() }
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
        return result
    }

    private func isSymbolicLink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    }

    private func isDescendant(_ child: URL, of parent: URL) -> Bool {
        let parentPath = parent.path.hasSuffix("/") ? parent.path : parent.path + "/"
        return child.path == parent.path || child.path.hasPrefix(parentPath)
    }
}
