import Foundation

public struct PrivilegedOperationPaths: Hashable, Sendable {
    public let root: URL

    public init(applicationSupport: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/ControlMyMac", isDirectory: true)) {
        root = applicationSupport.appendingPathComponent("authorization", isDirectory: true)
    }

    public init(root: URL) { self.root = root.standardizedFileURL }
    public var requests: URL { root.appendingPathComponent("requests", isDirectory: true) }
    public var audit: URL { root.appendingPathComponent("manual-handoff-audit.jsonl") }
    public func request(_ id: PrivilegedOperationRequestID) -> URL {
        requests.appendingPathComponent("\(id.description).json")
    }
}

public enum PrivilegedOperationStoreError: Error, Equatable, Sendable {
    case unsafePath
    case missingRequest
    case encodeFailure
    case decodeFailure
}

public enum PrivilegedOperationAuditEventKind: String, Codable, Sendable {
    case approved
    case commandCopied = "command_copied"
    case manualExecutionRequired = "manual_execution_required"
    case cancelled
    case expired
}

public struct PrivilegedOperationAuditEvent: Codable, Hashable, Sendable {
    public let requestID: PrivilegedOperationRequestID
    public let operationID: PrivilegedOperationID
    public let payloadDigest: String
    public let kind: PrivilegedOperationAuditEventKind
    public let createdAt: Date

    public init(request: PrivilegedOperationRequest, kind: PrivilegedOperationAuditEventKind, createdAt: Date = Date()) {
        requestID = request.id
        operationID = request.payload.operationID
        payloadDigest = request.payloadDigest
        self.kind = kind
        self.createdAt = createdAt
    }
}

public final class PrivilegedOperationStore {
    public let paths: PrivilegedOperationPaths
    private let fileManager: FileManager

    public init(paths: PrivilegedOperationPaths = .init(), fileManager: FileManager = .default) {
        self.paths = paths
        self.fileManager = fileManager
    }

    public func provision() throws {
        try createPrivateDirectory(paths.root)
        try createPrivateDirectory(paths.requests)
    }

    public func save(_ request: PrivilegedOperationRequest) throws {
        try provision()
        let target = paths.request(request.id)
        guard !isSymbolicLink(target) else { throw PrivilegedOperationStoreError.unsafePath }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(request) else { throw PrivilegedOperationStoreError.encodeFailure }
        try atomicWrite(data, to: target)
    }

    public func load(_ id: PrivilegedOperationRequestID) throws -> PrivilegedOperationRequest {
        let url = paths.request(id)
        guard !isSymbolicLink(url), fileManager.fileExists(atPath: url.path) else {
            throw PrivilegedOperationStoreError.missingRequest
        }
        guard let data = try? Data(contentsOf: url) else { throw PrivilegedOperationStoreError.missingRequest }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let request = try? decoder.decode(PrivilegedOperationRequest.self, from: data) else {
            throw PrivilegedOperationStoreError.decodeFailure
        }
        return request
    }

    public func allRequests() throws -> [PrivilegedOperationRequest] {
        try provision()
        guard !isSymbolicLink(paths.requests) else { throw PrivilegedOperationStoreError.unsafePath }
        let entries = try fileManager.contentsOfDirectory(at: paths.requests, includingPropertiesForKeys: [.isSymbolicLinkKey])
        return try entries.filter { $0.pathExtension == "json" }.map { entry in
            guard !isSymbolicLink(entry), let id = UUID(uuidString: entry.deletingPathExtension().lastPathComponent) else {
                throw PrivilegedOperationStoreError.unsafePath
            }
            return try load(.init(value: id))
        }
    }

    public func appendAudit(_ event: PrivilegedOperationAuditEvent) throws {
        try provision()
        guard !isSymbolicLink(paths.audit) else { throw PrivilegedOperationStoreError.unsafePath }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(event) else { throw PrivilegedOperationStoreError.encodeFailure }
        let line = data + Data("\n".utf8)
        if fileManager.fileExists(atPath: paths.audit.path) {
            let handle = try FileHandle(forWritingTo: paths.audit)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
        } else {
            try atomicWrite(line, to: paths.audit)
        }
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: paths.audit.path)
    }

    private func createPrivateDirectory(_ url: URL) throws {
        guard !isSymbolicLink(url) else { throw PrivilegedOperationStoreError.unsafePath }
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        guard !isSymbolicLink(url) else { throw PrivilegedOperationStoreError.unsafePath }
    }

    private func atomicWrite(_ data: Data, to target: URL) throws {
        let temporary = target.deletingLastPathComponent()
            .appendingPathComponent(".\(target.lastPathComponent).\(UUID().uuidString).tmp")
        guard !fileManager.fileExists(atPath: temporary.path), !isSymbolicLink(temporary) else {
            throw PrivilegedOperationStoreError.unsafePath
        }
        do {
            try data.write(to: temporary, options: .withoutOverwriting)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
            if fileManager.fileExists(atPath: target.path) {
                _ = try fileManager.replaceItemAt(target, withItemAt: temporary)
            } else {
                try fileManager.moveItem(at: temporary, to: target)
            }
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw error
        }
    }

    private func isSymbolicLink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    }
}
