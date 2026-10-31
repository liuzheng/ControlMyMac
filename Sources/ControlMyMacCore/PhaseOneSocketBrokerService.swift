import Foundation

public final class PhaseOneSocketBrokerService {
    public let broker: PhaseOneBroker
    public let socketPath: String
    private let expectedUID: uid_t
    private let lock = NSLock()
    private var server: UnixSocketServer?

    public var onRequestCreated: ((PrivilegedOperationRequest) -> Void)?

    public init(broker: PhaseOneBroker = .init(), expectedUID: uid_t = getuid()) {
        self.broker = broker
        self.expectedUID = expectedUID
        socketPath = broker.store.paths.root.appendingPathComponent("broker.sock").path
    }

    public func start() throws {
        lock.lock()
        defer { lock.unlock() }
        guard server == nil else { return }
        try broker.start()
        try broker.recover()
        let server = UnixSocketServer(path: socketPath, expectedUID: expectedUID) { [weak self] frame in
            self?.handle(frame) ?? Self.errorResponse(code: "broker_unavailable")
        }
        do {
            try server.start()
            self.server = server
        } catch {
            broker.stop()
            throw error
        }
    }

    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        server?.stop()
        server = nil
        broker.stop()
    }

    public func requests() throws -> [PrivilegedOperationRequest] {
        lock.lock()
        defer { lock.unlock() }
        return try broker.requests()
    }

    public func approve(_ id: PrivilegedOperationRequestID, expectedPayloadDigest: String) throws -> PrivilegedOperationRequest {
        lock.lock()
        defer { lock.unlock() }
        return try broker.approve(id, expectedPayloadDigest: expectedPayloadDigest)
    }

    public func recordManualHandoff(_ id: PrivilegedOperationRequestID) throws -> PrivilegedOperationRequest {
        lock.lock()
        defer { lock.unlock() }
        return try broker.recordManualHandoff(id)
    }

    private func handle(_ frame: Data) -> Data {
        lock.lock()
        defer { lock.unlock() }
        do {
            let request = try PrivilegedOperationFrameCodec.decode(frame)
            let response: PrivilegedOperationWireResponse
            switch request.action {
            case .create:
                let created = try broker.create(
                    payload: request.payload!,
                    origin: .init(uid: UInt32(expectedUID), label: "local-unix-socket"),
                    expiresAt: Date().addingTimeInterval(10 * 60)
                )
                onRequestCreated?(created)
                response = .init(requestID: created.id, state: created.state, result: created.result)
            case .status:
                let stored = try broker.status(request.requestID!)
                response = .init(requestID: stored.id, state: stored.state, result: stored.result)
            case .cancel:
                let cancelled = try broker.cancel(request.requestID!)
                response = .init(requestID: cancelled.id, state: cancelled.state, result: cancelled.result)
            }
            return try PrivilegedOperationFrameCodec.encodeResponse(response)
        } catch {
            return Self.errorResponse(code: "invalid_request")
        }
    }

    private static func errorResponse(code: String) -> Data {
        (try? PrivilegedOperationFrameCodec.encodeResponse(.init(errorCode: code))) ?? Data()
    }
}
