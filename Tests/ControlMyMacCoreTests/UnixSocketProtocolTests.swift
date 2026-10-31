import XCTest
@testable import ControlMyMacCore

final class UnixSocketProtocolTests: XCTestCase {
    private func payload() throws -> PrivilegedOperationPayload {
        try PrivilegedOperationPayload(
            operationID: .configureEN9,
            parameters: .configureEN9(try ConfigureEN9Parameters(interface: "en9", macAddress: "7c:8a:e1:8d:ab:2f", searchDomain: "cn1.global.ctrip.com"))
        )
    }

    func testFramesRoundTripOnlyValidCreateAndStatusShapes() throws {
        let create = PrivilegedOperationWireRequest(action: .create, payload: try payload())
        XCTAssertEqual(try PrivilegedOperationFrameCodec.decode(PrivilegedOperationFrameCodec.encode(create)).action, .create)

        let status = PrivilegedOperationWireRequest(action: .status, requestID: .init())
        XCTAssertEqual(try PrivilegedOperationFrameCodec.decode(PrivilegedOperationFrameCodec.encode(status)).action, .status)
    }

    func testRejectsUnsupportedVersionAndInvalidMessageShapes() throws {
        XCTAssertThrowsError(try PrivilegedOperationFrameCodec.encode(.init(protocolVersion: 99, action: .create, payload: try payload())))
        XCTAssertThrowsError(try PrivilegedOperationFrameCodec.encode(.init(action: .create)))
        XCTAssertThrowsError(try PrivilegedOperationFrameCodec.encode(.init(action: .cancel, payload: try payload())))
    }

    func testRejectsMalformedIncompleteAndOversizedFrames() throws {
        XCTAssertThrowsError(try PrivilegedOperationFrameCodec.decode(Data([0, 0, 0])))
        XCTAssertThrowsError(try PrivilegedOperationFrameCodec.decode(Data([0, 0, 0, 5, 1])))
        var oversized = UInt32(PrivilegedOperationFrameCodec.maximumPayloadBytes + 1).bigEndian
        XCTAssertThrowsError(try PrivilegedOperationFrameCodec.decode(Data(bytes: &oversized, count: 4))) { error in
            XCTAssertEqual(error as? PrivilegedOperationWireError, .oversizedFrame)
        }
    }
}
