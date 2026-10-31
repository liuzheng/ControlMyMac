import Darwin
import Foundation

public enum UnixSocketServerError: Error, Equatable, Sendable {
    case unsafePath
    case pathTooLong
    case createFailed(Int32)
    case bindFailed(Int32)
    case listenFailed(Int32)
    case peerRejected
}

/// A local AF_UNIX listener for phase one. It deliberately has no network
/// endpoint, no Helper registration, and no command execution capability.
public final class UnixSocketServer {
    public typealias FrameHandler = @Sendable (Data) -> Data

    public let path: String
    private let expectedUID: uid_t
    private let handler: FrameHandler
    private var descriptor: Int32 = -1
    private var source: DispatchSourceRead?
    private let queue = DispatchQueue(label: "com.liuzheng.controlmymac.phase-one-socket")

    public init(path: String, expectedUID: uid_t = getuid(), handler: @escaping FrameHandler) {
        self.path = path
        self.expectedUID = expectedUID
        self.handler = handler
    }

    deinit { stop() }

    public func start() throws {
        guard descriptor == -1 else { return }
        try preparePath()
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw UnixSocketServerError.createFailed(errno) }
        var noSigPipe: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else {
            Darwin.close(fd)
            throw UnixSocketServerError.createFailed(errno)
        }

        do {
            var address = try socketAddress()
            let result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(fd, $0, socketAddressLength())
                }
            }
            guard result == 0 else { throw UnixSocketServerError.bindFailed(errno) }
            guard Darwin.chmod(path, 0o600) == 0 else { throw UnixSocketServerError.bindFailed(errno) }
            guard Darwin.listen(fd, 16) == 0 else { throw UnixSocketServerError.listenFailed(errno) }
        } catch {
            Darwin.close(fd)
            try? removeSocketIfSafe()
            throw error
        }

        descriptor = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptPendingConnections() }
        source.setCancelHandler { Darwin.close(fd) }
        self.source = source
        source.resume()
    }

    public func stop() {
        source?.cancel()
        source = nil
        descriptor = -1
        try? removeSocketIfSafe()
    }

    private func acceptPendingConnections() {
        while true {
            let client = Darwin.accept(descriptor, nil, nil)
            guard client >= 0 else {
                if errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR { return }
                return
            }
            defer { Darwin.close(client) }
            let clientFlags = fcntl(client, F_GETFL)
            guard clientFlags >= 0, fcntl(client, F_SETFL, clientFlags & ~O_NONBLOCK) == 0 else { continue }
            guard peerUID(of: client) == expectedUID else { continue }
            guard let frame = readFrame(from: client), frame.count <= PrivilegedOperationFrameCodec.maximumPayloadBytes + 4 else { continue }
            let response = handler(frame)
            _ = response.withUnsafeBytes { raw in Darwin.write(client, raw.baseAddress, raw.count) }
        }
    }

    private func peerUID(of descriptor: Int32) -> uid_t? {
        var uid: uid_t = 0
        var gid: gid_t = 0
        return getpeereid(descriptor, &uid, &gid) == 0 ? uid : nil
    }

    private func readFrame(from descriptor: Int32) -> Data? {
        guard let header = readExactly(MemoryLayout<UInt32>.size, from: descriptor) else { return nil }
        let length = header.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
        guard length <= PrivilegedOperationFrameCodec.maximumPayloadBytes,
              let payload = readExactly(Int(length), from: descriptor) else { return nil }
        return header + payload
    }

    private func readExactly(_ count: Int, from descriptor: Int32) -> Data? {
        var buffer = Data(count: count)
        var offset = 0
        while offset < count {
            let received = buffer.withUnsafeMutableBytes { raw in
                Darwin.read(descriptor, raw.baseAddress!.advanced(by: offset), count - offset)
            }
            guard received > 0 else { return nil }
            offset += received
        }
        return buffer
    }

    private func preparePath() throws {
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent()
        let values = try? parent.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values?.isDirectory == true, values?.isSymbolicLink != true else { throw UnixSocketServerError.unsafePath }
        if FileManager.default.fileExists(atPath: path) {
            try removeSocketIfSafe()
        }
    }

    private func removeSocketIfSafe() throws {
        guard FileManager.default.fileExists(atPath: path) else { return }
        var status = stat()
        guard Darwin.lstat(path, &status) == 0, (status.st_mode & S_IFMT) == S_IFSOCK else {
            throw UnixSocketServerError.unsafePath
        }
        guard Darwin.unlink(path) == 0 else { throw UnixSocketServerError.unsafePath }
    }

    private func socketAddress() throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw UnixSocketServerError.pathTooLong }
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            destination.initializeMemory(as: UInt8.self, repeating: 0)
            destination.copyBytes(from: bytes)
        }
        return address
    }

    private func socketAddressLength() -> socklen_t {
        socklen_t(MemoryLayout<sa_family_t>.size + path.utf8.count + 1)
    }
}
