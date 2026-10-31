import Darwin
import Foundation
import XCTest
@testable import ControlMyMacCore

final class UnixSocketServerTests: XCTestCase {
    private let fileManager = FileManager.default

    func testSameUserClientRoundTripsFramedRequestAndSocketIsRemoved() throws {
        let directory = URL(fileURLWithPath: "/tmp/cmm-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try? self.fileManager.removeItem(at: directory) }
        let path = directory.appendingPathComponent("broker.sock").path
        let server = UnixSocketServer(path: path) { $0 }
        try server.start()
        XCTAssertTrue(fileManager.fileExists(atPath: path))

        let request = PrivilegedOperationWireRequest(action: .status, requestID: .init())
        let response = try send(PrivilegedOperationFrameCodec.encode(request), to: path)
        XCTAssertEqual(try PrivilegedOperationFrameCodec.decode(response).action, .status)

        server.stop()
        XCTAssertFalse(fileManager.fileExists(atPath: path))
    }

    private func send(_ frame: Data, to path: String) throws -> Data {
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer { Darwin.close(descriptor) }
        var address = try socketAddress(path)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sa_family_t>.size + path.utf8.count + 1))
            }
        }
        XCTAssertEqual(result, 0)
        _ = frame.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
        let header = try readExactly(4, descriptor: descriptor)
        let length = header.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
        return header + (try readExactly(Int(length), descriptor: descriptor))
    }

    private func readExactly(_ count: Int, descriptor: Int32) throws -> Data {
        var data = Data(count: count)
        var offset = 0
        while offset < count {
            let received = data.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress!.advanced(by: offset), count - offset) }
            guard received > 0 else { throw NSError(domain: "UnixSocketTest", code: Int(errno)) }
            offset += received
        }
        return data
    }

    private func socketAddress(_ path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw NSError(domain: "UnixSocketTest", code: 1) }
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            destination.initializeMemory(as: UInt8.self, repeating: 0)
            destination.copyBytes(from: bytes)
        }
        return address
    }
}
