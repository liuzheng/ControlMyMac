import CryptoKit
import Foundation

public struct PrivilegedOperationRequestID: Codable, Hashable, Sendable, CustomStringConvertible {
    public let value: UUID

    public init(value: UUID = UUID()) { self.value = value }
    public var description: String { value.uuidString.lowercased() }
}

public struct PrivilegedOperationID: Codable, Hashable, Sendable, RawRepresentable {
    public static let configureEN9 = Self(rawValue: "configure_en9")!
    public let rawValue: String

    public init?(rawValue: String) {
        guard rawValue.range(of: "^[a-z][a-z0-9_]{1,63}$", options: .regularExpression) != nil else {
            return nil
        }
        self.rawValue = rawValue
    }
}

public struct PrivilegedOperationOrigin: Codable, Hashable, Sendable {
    public let uid: UInt32
    public let label: String

    public init(uid: UInt32, label: String) {
        self.uid = uid
        self.label = label
    }
}

public struct PrivilegedApprovalPresentation: Codable, Hashable, Sendable {
    public let title: String?
    public let description: String?

    public init(title: String? = nil, description: String? = nil) throws {
        try Self.validate(title, field: "title", maximumLength: 80)
        try Self.validate(description, field: "description", maximumLength: 280)
        self.title = title
        self.description = description
    }

    private static func validate(_ value: String?, field: String, maximumLength: Int) throws {
        guard let value else { return }
        guard !value.isEmpty, value.count <= maximumLength,
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw PrivilegedOperationModelError.invalidApprovalPresentation(field)
        }
    }
}

public struct ConfigureEN9Parameters: Codable, Hashable, Sendable {
    public let interface: String
    public let macAddress: String
    public let searchDomain: String

    public init(interface: String, macAddress: String, searchDomain: String) throws {
        guard interface == "en9" else { throw PrivilegedOperationModelError.invalidParameter("interface") }
        guard macAddress.range(of: "^[0-9a-fA-F]{2}(:[0-9a-fA-F]{2}){5}$", options: .regularExpression) != nil else {
            throw PrivilegedOperationModelError.invalidParameter("mac_address")
        }
        guard searchDomain.range(of: "^(?=.{1,253}$)([A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\\.)+[A-Za-z]{2,63}$", options: .regularExpression) != nil else {
            throw PrivilegedOperationModelError.invalidParameter("search_domain")
        }
        self.interface = interface
        self.macAddress = macAddress.lowercased()
        self.searchDomain = searchDomain.lowercased()
    }
}

public enum PrivilegedOperationParameters: Codable, Hashable, Sendable {
    case configureEN9(ConfigureEN9Parameters)

    private enum CodingKeys: String, CodingKey { case type, value }
    private enum Kind: String, Codable { case configureEN9 }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .type) {
        case .configureEN9:
            self = .configureEN9(try container.decode(ConfigureEN9Parameters.self, forKey: .value))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .configureEN9(let value):
            try container.encode(Kind.configureEN9, forKey: .type)
            try container.encode(value, forKey: .value)
        }
    }
}

public struct PrivilegedOperationPayload: Codable, Hashable, Sendable {
    public let operationID: PrivilegedOperationID
    public let registryVersion: Int
    public let parameters: PrivilegedOperationParameters
    public let approval: PrivilegedApprovalPresentation

    public init(operationID: PrivilegedOperationID, registryVersion: Int = 1,
                parameters: PrivilegedOperationParameters, approval: PrivilegedApprovalPresentation = try! .init()) throws {
        guard registryVersion > 0 else { throw PrivilegedOperationModelError.invalidRegistryVersion }
        guard operationID == .configureEN9, case .configureEN9 = parameters else {
            throw PrivilegedOperationModelError.operationParameterMismatch
        }
        self.operationID = operationID
        self.registryVersion = registryVersion
        self.parameters = parameters
        self.approval = approval
    }

    public var digest: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = (try? encoder.encode(self)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

public enum PrivilegedOperationState: String, Codable, CaseIterable, Sendable {
    case pendingAuthorization = "pending_authorization"
    case authorized
    case running
    case succeeded
    case failed
    case cancelled
    case expired
    case manualExecutionRequired = "manual_execution_required"

    public var isTerminal: Bool {
        switch self {
        case .succeeded, .failed, .cancelled, .expired, .manualExecutionRequired: true
        case .pendingAuthorization, .authorized, .running: false
        }
    }

    public func canTransition(to destination: Self) -> Bool {
        switch (self, destination) {
        case (.pendingAuthorization, .authorized),
             (.pendingAuthorization, .cancelled),
             (.pendingAuthorization, .expired),
             (.authorized, .running),
             (.authorized, .manualExecutionRequired),
             (.authorized, .cancelled),
             (.authorized, .expired),
             (.running, .succeeded),
             (.running, .failed),
             (.running, .cancelled):
            return true
        default:
            return false
        }
    }
}

public enum PrivilegedOperationAuditClassification: String, Codable, Sendable {
    case networkConfiguration
    case manualTerminalHandoff
}

public struct PrivilegedOperationSafeResult: Codable, Hashable, Sendable {
    public let code: String
    public let message: String
    public let partialEffectPossible: Bool

    public init(code: String, message: String, partialEffectPossible: Bool = false) {
        self.code = code
        self.message = message
        self.partialEffectPossible = partialEffectPossible
    }
}

public struct PrivilegedOperationRequest: Codable, Hashable, Sendable {
    public let id: PrivilegedOperationRequestID
    public let payload: PrivilegedOperationPayload
    public let payloadDigest: String
    public let origin: PrivilegedOperationOrigin
    public let createdAt: Date
    public let expiresAt: Date
    public private(set) var state: PrivilegedOperationState
    public private(set) var result: PrivilegedOperationSafeResult?

    public init(id: PrivilegedOperationRequestID = .init(), payload: PrivilegedOperationPayload,
                origin: PrivilegedOperationOrigin, createdAt: Date = Date(), expiresAt: Date) throws {
        guard expiresAt > createdAt else { throw PrivilegedOperationModelError.invalidExpiry }
        self.id = id
        self.payload = payload
        self.payloadDigest = payload.digest
        self.origin = origin
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        state = .pendingAuthorization
    }

    public mutating func transition(to destination: PrivilegedOperationState,
                                    result: PrivilegedOperationSafeResult? = nil,
                                    now: Date = Date()) throws {
        guard !state.isTerminal else { throw PrivilegedOperationModelError.terminalRequest }
        guard now <= expiresAt || destination == .expired else { throw PrivilegedOperationModelError.expiredRequest }
        guard state.canTransition(to: destination) else { throw PrivilegedOperationModelError.illegalTransition(state, destination) }
        state = destination
        self.result = result
    }
}

public enum PrivilegedOperationModelError: Error, Equatable, Sendable {
    case invalidApprovalPresentation(String)
    case invalidParameter(String)
    case invalidRegistryVersion
    case operationParameterMismatch
    case invalidExpiry
    case terminalRequest
    case expiredRequest
    case illegalTransition(PrivilegedOperationState, PrivilegedOperationState)
}
