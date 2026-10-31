import Foundation
import XCTest
@testable import ControlMyMacCore

final class PhaseOneBrokerTests: XCTestCase {
    private let fileManager = FileManager.default

    private func broker() throws -> PhaseOneBroker {
        let root = fileManager.temporaryDirectory.appendingPathComponent("ControlMyMacBroker-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? self.fileManager.removeItem(at: root) }
        return PhaseOneBroker(store: .init(paths: .init(root: root)))
    }

    private func payload() throws -> PrivilegedOperationPayload {
        try PrivilegedOperationPayload(
            operationID: .configureEN9,
            parameters: .configureEN9(try ConfigureEN9Parameters(interface: "en9", macAddress: "7c:8a:e1:8d:ab:2f", searchDomain: "cn1.global.ctrip.com"))
        )
    }

    func testStartCreatesOnlyPrivateUserState() throws {
        let broker = try broker()
        try broker.start()
        XCTAssertEqual(broker.state, .running)
        XCTAssertTrue(fileManager.fileExists(atPath: broker.store.paths.root.path))
        XCTAssertFalse(fileManager.fileExists(atPath: broker.store.paths.root.appendingPathComponent("helper").path))
    }

    func testCreateCancelAndManualHandoffDoNotExecuteOperation() throws {
        let broker = try broker()
        try broker.start()
        let request = try broker.create(payload: payload(), origin: .init(uid: 501, label: "dag"), expiresAt: Date().addingTimeInterval(60))
        XCTAssertEqual(request.state, .pendingAuthorization)

        var authorized = try broker.store.load(request.id)
        try authorized.transition(to: .authorized)
        try broker.store.save(authorized)
        let handoff = try broker.recordManualHandoff(request.id)
        XCTAssertEqual(handoff.state, .manualExecutionRequired)
        XCTAssertTrue(handoff.state.isTerminal)

        let another = try broker.create(payload: payload(), origin: .init(uid: 501, label: "dag"), expiresAt: Date().addingTimeInterval(60))
        let cancelled = try broker.cancel(another.id)
        XCTAssertEqual(cancelled.state, .cancelled)
    }

    func testRequestsFailWhenBrokerIsNotRunning() throws {
        let broker = try broker()
        XCTAssertThrowsError(try broker.create(payload: payload(), origin: .init(uid: 501, label: "dag"), expiresAt: Date().addingTimeInterval(60))) { error in
            XCTAssertEqual(error as? PhaseOneBrokerError, .notRunning)
        }
    }
}


extension PhaseOneBrokerTests {
    func testRecoveryExpiresAndInterruptsWithoutRevivingTerminalRequests() throws {
        let broker = try broker()
        try broker.start()
        let now = Date()
        let expired = try PrivilegedOperationRequest(
            payload: try payload(),
            origin: .init(uid: 501, label: "dag"),
            createdAt: now.addingTimeInterval(-2),
            expiresAt: now.addingTimeInterval(-1)
        )
        try broker.store.save(expired)
        let authorized = try broker.create(payload: payload(), origin: .init(uid: 501, label: "dag"), expiresAt: now.addingTimeInterval(60))
        var authorizedState = try broker.store.load(authorized.id)
        try authorizedState.transition(to: .authorized, now: now)
        try broker.store.save(authorizedState)
        let pending = try broker.create(payload: payload(), origin: .init(uid: 501, label: "dag"), expiresAt: now.addingTimeInterval(60))
        let terminal = try broker.create(payload: payload(), origin: .init(uid: 501, label: "dag"), expiresAt: now.addingTimeInterval(60))
        _ = try broker.cancel(terminal.id, now: now)

        try broker.recover(now: now)
        XCTAssertEqual(try broker.status(expired.id).state, .expired)
        XCTAssertEqual(try broker.status(authorized.id).state, .cancelled)
        XCTAssertEqual(try broker.status(pending.id).state, .pendingAuthorization)
        XCTAssertEqual(try broker.status(terminal.id).state, .cancelled)
    }
}


extension PhaseOneBrokerTests {
    func testApprovalIsBoundToExactPayloadDigestAndSingleRequestState() throws {
        let broker = try broker()
        try broker.start()
        let request = try broker.create(payload: payload(), origin: .init(uid: 501, label: "dag"), expiresAt: Date().addingTimeInterval(60))

        XCTAssertThrowsError(try broker.approve(request.id, expectedPayloadDigest: "different")) { error in
            XCTAssertEqual(error as? PhaseOneBrokerError, .payloadChanged)
        }
        let approved = try broker.approve(request.id, expectedPayloadDigest: request.payloadDigest)
        XCTAssertEqual(approved.state, .authorized)
        XCTAssertThrowsError(try broker.approve(request.id, expectedPayloadDigest: request.payloadDigest))
    }
}
