import Foundation

public enum PhaseOneBrokerState: String, Sendable {
    case stopped
    case running
    case failed
}

public final class PhaseOneBroker {
    public private(set) var state: PhaseOneBrokerState = .stopped
    public let store: PrivilegedOperationStore
    public let registry: PrivilegedOperationRegistry

    public init(store: PrivilegedOperationStore = .init(), registry: PrivilegedOperationRegistry = .init()) {
        self.store = store
        self.registry = registry
    }

    public func start() throws {
        do {
            try store.provision()
            state = .running
        } catch {
            state = .failed
            throw error
        }
    }

    public func stop() { state = .stopped }

    public func create(payload: PrivilegedOperationPayload, origin: PrivilegedOperationOrigin,
                       expiresAt: Date) throws -> PrivilegedOperationRequest {
        guard state == .running else { throw PhaseOneBrokerError.notRunning }
        try registry.validate(payload)
        let request = try PrivilegedOperationRequest(payload: payload, origin: origin, expiresAt: expiresAt)
        try store.save(request)
        return request
    }

    public func recover(now: Date = Date()) throws {
        guard state == .running else { throw PhaseOneBrokerError.notRunning }
        for var request in try store.allRequests() {
            guard !request.state.isTerminal else { continue }
            if request.expiresAt < now {
                try request.transition(to: .expired, result: .init(code: "expired", message: "Request expired"), now: now)
                try store.save(request)
                try store.appendAudit(.init(request: request, kind: .expired, createdAt: now))
            } else if request.state == .authorized || request.state == .running {
                try request.transition(to: .cancelled, result: .init(code: "interrupted", message: "Broker restarted; approval was not reused"), now: now)
                try store.save(request)
                try store.appendAudit(.init(request: request, kind: .cancelled, createdAt: now))
            }
        }
    }

    public func requests() throws -> [PrivilegedOperationRequest] {
        guard state == .running else { throw PhaseOneBrokerError.notRunning }
        return try store.allRequests().sorted { $0.createdAt > $1.createdAt }
    }

    public func approve(_ id: PrivilegedOperationRequestID, expectedPayloadDigest: String, now: Date = Date()) throws -> PrivilegedOperationRequest {
        guard state == .running else { throw PhaseOneBrokerError.notRunning }
        var request = try store.load(id)
        guard request.payloadDigest == expectedPayloadDigest else { throw PhaseOneBrokerError.payloadChanged }
        try request.transition(to: .authorized, result: .init(code: "authorized", message: "Awaiting manual terminal handoff"), now: now)
        try store.save(request)
        try store.appendAudit(.init(request: request, kind: .approved, createdAt: now))
        return request
    }

    public func status(_ id: PrivilegedOperationRequestID) throws -> PrivilegedOperationRequest {
        guard state == .running else { throw PhaseOneBrokerError.notRunning }
        return try store.load(id)
    }

    public func cancel(_ id: PrivilegedOperationRequestID, now: Date = Date()) throws -> PrivilegedOperationRequest {
        guard state == .running else { throw PhaseOneBrokerError.notRunning }
        var request = try store.load(id)
        try request.transition(to: .cancelled, result: .init(code: "cancelled", message: "Request cancelled"), now: now)
        try store.save(request)
        try store.appendAudit(.init(request: request, kind: .cancelled, createdAt: now))
        return request
    }

    public func recordManualHandoff(_ id: PrivilegedOperationRequestID, now: Date = Date()) throws -> PrivilegedOperationRequest {
        guard state == .running else { throw PhaseOneBrokerError.notRunning }
        var request = try store.load(id)
        try request.transition(to: .manualExecutionRequired,
                               result: .init(code: "manual_execution_required", message: "Terminal execution has not been verified"),
                               now: now)
        try store.save(request)
        try store.appendAudit(.init(request: request, kind: .commandCopied, createdAt: now))
        try store.appendAudit(.init(request: request, kind: .manualExecutionRequired, createdAt: now))
        return request
    }
}

public enum PhaseOneBrokerError: Error, Equatable, Sendable {
    case notRunning
    case payloadChanged
}
