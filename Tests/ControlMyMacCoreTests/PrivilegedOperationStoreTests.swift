import Foundation
import XCTest
@testable import ControlMyMacCore

final class PrivilegedOperationStoreTests: XCTestCase {
    private let fileManager = FileManager.default

    private func store() throws -> PrivilegedOperationStore {
        let root = fileManager.temporaryDirectory.appendingPathComponent("ControlMyMacAuthorization-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? self.fileManager.removeItem(at: root) }
        return PrivilegedOperationStore(paths: .init(root: root))
    }

    private func request() throws -> PrivilegedOperationRequest {
        let payload = try PrivilegedOperationPayload(
            operationID: .configureEN9,
            parameters: .configureEN9(try ConfigureEN9Parameters(
                interface: "en9", macAddress: "7c:8a:e1:8d:ab:2f", searchDomain: "cn1.global.ctrip.com"
            ))
        )
        return try PrivilegedOperationRequest(
            payload: payload,
            origin: .init(uid: 501, label: "test"),
            expiresAt: Date().addingTimeInterval(60)
        )
    }

    func testStoreUsesPrivateDirectoriesAndRequestFiles() throws {
        let store = try store()
        let saved = try request()
        try store.save(saved)

        let loaded = try store.load(saved.id)
        XCTAssertEqual(loaded.id, saved.id)
        XCTAssertEqual(loaded.payloadDigest, saved.payloadDigest)
        XCTAssertEqual(loaded.origin, saved.origin)
        XCTAssertEqual(loaded.state, saved.state)
        XCTAssertEqual(loaded.result, saved.result)
        XCTAssertEqual(try fileManager.attributesOfItem(atPath: store.paths.root.path)[.posixPermissions] as? Int, 0o700)
        XCTAssertEqual(try fileManager.attributesOfItem(atPath: store.paths.requests.path)[.posixPermissions] as? Int, 0o700)
        XCTAssertEqual(try fileManager.attributesOfItem(atPath: store.paths.request(saved.id).path)[.posixPermissions] as? Int, 0o600)

        var approved = saved
        try approved.transition(to: .authorized)
        try store.save(approved)
        XCTAssertEqual(try store.load(saved.id).state, .authorized)
    }

    func testStoreRejectsSymlinkedRequestAndAuditPaths() throws {
        let store = try store()
        try store.provision()
        let saved = try request()
        let outside = fileManager.temporaryDirectory.appendingPathComponent("outside-\(UUID().uuidString)")
        try "outside".write(to: outside, atomically: true, encoding: .utf8)
        addTeardownBlock { try? self.fileManager.removeItem(at: outside) }
        try fileManager.createSymbolicLink(at: store.paths.request(saved.id), withDestinationURL: outside)
        XCTAssertThrowsError(try store.save(saved)) { error in
            XCTAssertEqual(error as? PrivilegedOperationStoreError, .unsafePath)
        }

        try fileManager.removeItem(at: store.paths.request(saved.id))
        try fileManager.createSymbolicLink(at: store.paths.audit, withDestinationURL: outside)
        XCTAssertThrowsError(try store.appendAudit(.init(request: saved, kind: .commandCopied))) { error in
            XCTAssertEqual(error as? PrivilegedOperationStoreError, .unsafePath)
        }
    }

    func testManualHandoffAuditNeverClaimsSuccess() throws {
        let store = try store()
        var saved = try request()
        try saved.transition(to: .authorized)
        try saved.transition(to: .manualExecutionRequired, result: .init(code: "manual_execution_required", message: "copy"))
        try store.save(saved)
        try store.appendAudit(.init(request: saved, kind: .approved))
        try store.appendAudit(.init(request: saved, kind: .commandCopied))
        try store.appendAudit(.init(request: saved, kind: .manualExecutionRequired))

        let audit = try String(contentsOf: store.paths.audit)
        XCTAssertTrue(audit.contains("manual_execution_required"))
        XCTAssertFalse(audit.contains("succeeded"))
        XCTAssertEqual(try fileManager.attributesOfItem(atPath: store.paths.audit.path)[.posixPermissions] as? Int, 0o600)
    }
}
