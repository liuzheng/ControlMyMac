import Darwin
import Foundation
import XCTest
@testable import ControlMyMacCore

final class PhaseOneSocketBrokerServiceTests: XCTestCase {
    private let fileManager = FileManager.default

    func testAppHostedServiceRoutesCreateStatusAndCancelThenRemovesSocket() throws {
        let root = URL(fileURLWithPath: "/tmp/cmm-service-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? self.fileManager.removeItem(at: root) }
        let service = PhaseOneSocketBrokerService(broker: .init(store: .init(paths: .init(root: root))))
        try service.start()
        XCTAssertTrue(fileManager.fileExists(atPath: service.socketPath))

        let payload = try PrivilegedOperationPayload(
            operationID: .configureEN9,
            parameters: .configureEN9(try ConfigureEN9Parameters(interface: "en9", macAddress: "7c:8a:e1:8d:ab:2f", searchDomain: "cn1.global.ctrip.com"))
        )
        let created = try response(for: .init(action: .create, payload: payload), path: service.socketPath)
        XCTAssertEqual(created.state, .pendingAuthorization)
        let id = try XCTUnwrap(created.requestID)

        let status = try response(for: .init(action: .status, requestID: id), path: service.socketPath)
        XCTAssertEqual(status.requestID, id)
        XCTAssertEqual(status.state, .pendingAuthorization)

        let cancelled = try response(for: .init(action: .cancel, requestID: id), path: service.socketPath)
        XCTAssertEqual(cancelled.state, .cancelled)
        service.stop()
        XCTAssertFalse(fileManager.fileExists(atPath: service.socketPath))
    }

    private func response(for request: PrivilegedOperationWireRequest, path: String) throws -> PrivilegedOperationWireResponse {
        let frame = try PrivilegedOperationFrameCodec.encode(request)
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        defer { Darwin.close(descriptor) }
        var address = try socketAddress(path)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sa_family_t>.size + path.utf8.count + 1))
            }
        }
        XCTAssertEqual(connected, 0)
        _ = frame.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
        let header = try readExactly(4, descriptor: descriptor)
        let length = header.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
        let payload = try readExactly(Int(length), descriptor: descriptor)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(PrivilegedOperationWireResponse.self, from: payload)
    }

    private func readExactly(_ count: Int, descriptor: Int32) throws -> Data {
        var data = Data(count: count)
        var offset = 0
        while offset < count {
            let received = data.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress!.advanced(by: offset), count - offset) }
            guard received > 0 else { throw NSError(domain: "PhaseOneSocketTest", code: Int(errno)) }
            offset += received
        }
        return data
    }

    private func socketAddress(_ path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw NSError(domain: "PhaseOneSocketTest", code: 1) }
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            destination.initializeMemory(as: UInt8.self, repeating: 0)
            destination.copyBytes(from: bytes)
        }
        return address
    }
}
