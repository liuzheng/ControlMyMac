import Foundation
import XCTest
@testable import ControlMyMacCore

final class AirflowServiceTests: XCTestCase {
    private let fileManager = FileManager.default

    private func temporaryPaths() throws -> AirflowPaths {
        let home = fileManager.temporaryDirectory.appendingPathComponent("ControlMyMacAirflow-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: home, withIntermediateDirectories: true)
        addTeardownBlock { try? self.fileManager.removeItem(at: home) }
        return AirflowPaths(home: home)
    }

    func testWorkspaceProvisionPreservesDAGsAndWritesResolvedConfiguration() throws {
        let paths = try temporaryPaths()
        try fileManager.createDirectory(at: paths.dags, withIntermediateDirectories: true)
        let dag = paths.dags.appendingPathComponent("existing.py")
        try "# preserved DAG".write(to: dag, atomically: true, encoding: .utf8)
        try AirflowWorkspace(paths: paths).provision(date: Date(timeIntervalSince1970: 1_735_689_600))

        XCTAssertEqual(try String(contentsOf: dag), "# preserved DAG")
        let config = try String(contentsOf: paths.runtimeConfig)
        XCTAssertTrue(config.contains("dags_folder = \(paths.dags.path)"))
        let databasePath = paths.airflowHome.appendingPathComponent("airflow.db").path
        XCTAssertTrue(config.contains("sqlite:///\(databasePath)"))
        XCTAssertTrue(config.contains(paths.logRoot.path))
        XCTAssertTrue(config.contains("simple_auth_manager_users = controlmymac:admin"))
        XCTAssertTrue(config.contains("simple_auth_manager_all_admins = False"))
        XCTAssertTrue(config.contains("simple_auth_manager_passwords_file = \(paths.simpleAuthPasswords.path)"))
        XCTAssertTrue(config.contains("execution_api_server_url = \(AirflowPaths.endpoint.absoluteString)/execution/"))
        for category in AirflowLogCategory.allCases {
            XCTAssertTrue(fileManager.fileExists(atPath: paths.logDirectory(category: category,
                                                                             date: Date(timeIntervalSince1970: 1_735_689_600)).path))
        }
    }

    func testRuntimeValidationFailsWithoutTrustedRuntimeBeforeVersionReader() throws {
        let paths = try temporaryPaths()
        var versionReaderCalled = false
        let validator = AirflowRuntimeValidator(
            runtime: PythonRuntime(bundleURL: paths.home.appendingPathComponent("missing.app")),
            packageDirectory: paths.home.appendingPathComponent("python-packages"),
            versionReader: { _, _ in versionReaderCalled = true; return ProcResult(status: 0, out: "3.3.2", err: "") })
        guard case .failure(.runtime) = validator.validate() else {
            return XCTFail("missing trusted runtime must fail")
        }
        XCTAssertFalse(versionReaderCalled)
    }

    func testServiceStateUsesOnlyAirflowPhase() throws {
        let paths = try temporaryPaths()
        XCTAssertFalse(AirflowServiceStatus(phase: .stopped, paths: paths).isRunning)
        XCTAssertFalse(AirflowServiceStatus(phase: .starting, paths: paths).isRunning)
        XCTAssertTrue(AirflowServiceStatus(phase: .ready, paths: paths).isRunning)
        XCTAssertFalse(AirflowServiceStatus(phase: .failed, paths: paths).isRunning)
    }

    func testControllerUsesOnlyAirflowGUIJobAndMapsReadinessStates() throws {
        let paths = try temporaryPaths()
        var commands: [(String, [String])] = []
        let controller = AirflowServiceController(paths: paths, uid: 501,
            command: { path, args in
                commands.append((path, args))
                return ProcResult(status: 0, out: "state = running\nlast exit code = 0", err: "")
            }, readinessProbe: { false })
        XCTAssertEqual(controller.status().phase, .starting)
        XCTAssertEqual(controller.start().status, 0)
        XCTAssertEqual(commands.map(\.1), [["print", "gui/501/com.liuzheng.controlmymac.airflow"],
                                            ["enable", "gui/501/com.liuzheng.controlmymac.airflow"],
                                            ["kickstart", "-k", "gui/501/com.liuzheng.controlmymac.airflow"]])

        let ready = AirflowServiceController(paths: paths, uid: 501,
            command: { _, _ in ProcResult(status: 0, out: "state = running", err: "") }, readinessProbe: { true })
        XCTAssertEqual(ready.status().phase, .ready)
        let failed = AirflowServiceController(paths: paths, uid: 501,
            command: { _, _ in ProcResult(status: 0, out: "last exit code = 78", err: "") }, readinessProbe: { false })
        XCTAssertEqual(failed.status().phase, .failed)
    }

    func testRetentionPersistsAndCleanupKeepsBoundaryCurrentAndExternalContent() throws {
        let paths = try temporaryPaths()
        let defaults = UserDefaults(suiteName: "ControlMyMacAirflowTests-\(UUID().uuidString)")!
        defer { defaults.removePersistentDomain(forName: defaults.description) }
        XCTAssertEqual(AirflowLogSettings.retention(defaults: defaults).days, 30)
        try AirflowLogSettings.save(days: 7, paths: paths, defaults: defaults)
        XCTAssertEqual(AirflowLogSettings.retention(defaults: defaults).days, 7)
        XCTAssertNotNil(AirflowLogRetention(days: 7))
        XCTAssertThrowsError(try AirflowLogSettings.save(days: 0, paths: paths, defaults: defaults))

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = calendar.date(from: DateComponents(year: 2025, month: 3, day: 31, hour: 12))!
        for name in ["2025-03-23", "2025-03-24", "2025-03-31"] {
            try fileManager.createDirectory(at: paths.logRoot.appendingPathComponent("tasks/\(name)"), withIntermediateDirectories: true)
        }
        let outside = paths.home.appendingPathComponent("outside")
        try fileManager.createDirectory(at: outside, withIntermediateDirectories: true)
        try fileManager.createSymbolicLink(at: paths.logRoot.appendingPathComponent("tasks/2025-03-01"), withDestinationURL: outside)

        let result = AirflowLogCleaner(paths: paths).clean(retention: AirflowLogRetention(days: 7)!, now: now, calendar: calendar)
        XCTAssertEqual(result.deletedItems, 1)
        XCTAssertFalse(fileManager.fileExists(atPath: paths.logRoot.appendingPathComponent("tasks/2025-03-23").path))
        XCTAssertTrue(fileManager.fileExists(atPath: paths.logRoot.appendingPathComponent("tasks/2025-03-24").path))
        XCTAssertTrue(fileManager.fileExists(atPath: paths.logRoot.appendingPathComponent("tasks/2025-03-31").path))
        XCTAssertTrue(fileManager.fileExists(atPath: outside.path))
        XCTAssertTrue(result.diagnostic.contains("跳过根目录外或符号链接"))
        XCTAssertNotNil(AirflowCleanupResult.read(from: paths.cleanupStatus))
    }
}


extension AirflowServiceTests {
    func testSimpleAuthCredentialsRequirePrivateFixedUserRecord() throws {
        let paths = try temporaryPaths()
        try fileManager.createDirectory(at: paths.airflowHome, withIntermediateDirectories: true)
        let passwordFile = paths.simpleAuthPasswords
        try "{\"controlmymac\":\"test-password\"}".write(to: passwordFile, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: passwordFile.path)

        XCTAssertEqual(AirflowSimpleAuthCredentials.read(from: passwordFile)?.userName, "controlmymac")
        XCTAssertNotNil(AirflowSimpleAuthCredentials.read(from: passwordFile)?.password)

        try fileManager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: passwordFile.path)
        XCTAssertNil(AirflowSimpleAuthCredentials.read(from: passwordFile))
        try "{\"other\":\"test-password\"}".write(to: passwordFile, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: passwordFile.path)
        XCTAssertNil(AirflowSimpleAuthCredentials.read(from: passwordFile))
    }

    func testDiagnosticReadsPythonTimestampAndInstallerDiagnosticWithoutTimestamp() throws {
        let paths = try temporaryPaths()
        try fileManager.createDirectory(at: paths.airflowHome, withIntermediateDirectories: true)
        try "{\"phase\":\"failed\",\"message\":\"safe diagnostic\",\"updatedAt\":\"2025-03-31T12:34:56.123456\"}".write(to: paths.diagnostic, atomically: true, encoding: .utf8)
        XCTAssertEqual(AirflowDiagnostic.read(from: paths.diagnostic)?.message, "safe diagnostic")
        try "{\"phase\":\"failed\",\"message\":\"safe diagnostic\"}".write(to: paths.diagnostic, atomically: true, encoding: .utf8)
        XCTAssertEqual(AirflowDiagnostic.read(from: paths.diagnostic)?.phase, .failed)
    }
}
