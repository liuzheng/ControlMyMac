import Foundation
import XCTest
@testable import ControlMyMacCore

final class PythonRuntimeTests: XCTestCase {
    private var bundleURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("build/ControlMyMac.app")
    }

    func testMissingRuntimeDoesNotFallback() {
        let runtime = PythonRuntime(bundleURL: URL(fileURLWithPath: "/tmp/no-controlmymac-python-bundle"))
        let status = runtime.status()
        XCTAssertFalse(status.available)
        XCTAssertFalse(status.manifestValid)
        XCTAssertTrue(status.lastError.contains("manifest"))
    }

    func testBundledPythonRuntimeValidatesWhenBundleExists() throws {
        guard FileManager.default.fileExists(atPath: bundleURL.path) else {
            throw XCTSkip("release bundle not prepared")
        }
        let status = PythonRuntime(bundleURL: bundleURL).status()
        XCTAssertTrue(status.available, status.lastError)
        XCTAssertEqual(status.version, "3.14.7")
        XCTAssertTrue(status.architecture == "arm64" || status.architecture == "x86_64")
    }
}
