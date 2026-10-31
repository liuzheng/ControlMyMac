import XCTest
@testable import ControlMyMacCore

final class PrivilegedOperationModelsTests: XCTestCase {
    private func payload() throws -> PrivilegedOperationPayload {
        try PrivilegedOperationPayload(
            operationID: .configureEN9,
            parameters: .configureEN9(try ConfigureEN9Parameters(
                interface: "en9",
                macAddress: "7C:8A:E1:8D:AB:2F",
                searchDomain: "CN1.GLOBAL.CTRIP.COM"
            )),
            approval: try .init(title: "配置网络", description: "应用已注册的 en9 设置")
        )
    }

    func testConfigureEN9NormalizesPayloadAndProducesStableDigest() throws {
        let first = try payload()
        let second = try payload()

        XCTAssertEqual(first.parameters, second.parameters)
        XCTAssertEqual(first.digest, second.digest)
        guard case .configureEN9(let value) = first.parameters else { return XCTFail("wrong parameters") }
        XCTAssertEqual(value.macAddress, "7c:8a:e1:8d:ab:2f")
        XCTAssertEqual(value.searchDomain, "cn1.global.ctrip.com")
    }

    func testRejectsUnapprovedNetworkParametersAndUnsafePresentation() throws {
        XCTAssertThrowsError(try ConfigureEN9Parameters(interface: "en8", macAddress: "7c:8a:e1:8d:ab:2f", searchDomain: "cn1.global.ctrip.com"))
        XCTAssertThrowsError(try ConfigureEN9Parameters(interface: "en9", macAddress: "not-a-mac", searchDomain: "cn1.global.ctrip.com"))
        XCTAssertThrowsError(try ConfigureEN9Parameters(interface: "en9", macAddress: "7c:8a:e1:8d:ab:2f", searchDomain: "domain;rm.example"))
        XCTAssertThrowsError(try PrivilegedApprovalPresentation(title: "safe\nunsafe"))
    }

    func testStateMachineSupportsManualHandoffButNotFalseSuccess() throws {
        let now = Date(timeIntervalSince1970: 100)
        var request = try PrivilegedOperationRequest(
            payload: try payload(),
            origin: .init(uid: 501, label: "test"),
            createdAt: now,
            expiresAt: now.addingTimeInterval(60)
        )

        try request.transition(to: .authorized, now: now)
        try request.transition(to: .manualExecutionRequired,
                               result: .init(code: "manual_execution_required", message: "Run reviewed command in Terminal"),
                               now: now)
        XCTAssertTrue(request.state.isTerminal)
        XCTAssertEqual(request.state, .manualExecutionRequired)
        XCTAssertThrowsError(try request.transition(to: .succeeded, now: now))
    }

    func testStateMachineRejectsDuplicateIllegalAndExpiredTransitions() throws {
        let now = Date(timeIntervalSince1970: 100)
        var request = try PrivilegedOperationRequest(
            payload: try payload(), origin: .init(uid: 501, label: "test"),
            createdAt: now, expiresAt: now.addingTimeInterval(10)
        )

        XCTAssertThrowsError(try request.transition(to: .succeeded, now: now))
        XCTAssertThrowsError(try request.transition(to: .authorized, now: now.addingTimeInterval(11)))
        try request.transition(to: .expired, now: now.addingTimeInterval(11))
        XCTAssertThrowsError(try request.transition(to: .cancelled, now: now.addingTimeInterval(11)))
    }

    func testRequestRejectsInvalidExpiry() throws {
        let now = Date()
        XCTAssertThrowsError(try PrivilegedOperationRequest(
            payload: try payload(), origin: .init(uid: 501, label: "test"),
            createdAt: now, expiresAt: now
        ))
    }
}
