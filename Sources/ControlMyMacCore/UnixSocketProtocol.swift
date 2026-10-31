import Foundation

public enum PrivilegedOperationWireAction: String, Codable, Sendable {
    case create
    case status
    case cancel
}

public struct PrivilegedOperationWireRequest: Codable, Sendable {
    public let protocolVersion: Int
    public let action: PrivilegedOperationWireAction
    public let payload: PrivilegedOperationPayload?
    public let requestID: PrivilegedOperationRequestID?

    public init(protocolVersion: Int = PrivilegedServiceFoundation.protocolVersion,
                action: PrivilegedOperationWireAction,
                payload: PrivilegedOperationPayload? = nil,
                requestID: PrivilegedOperationRequestID? = nil) {
        self.protocolVersion = protocolVersion
        self.action = action
        self.payload = payload
        self.requestID = requestID
    }

    public func validate() throws {
        guard protocolVersion == PrivilegedServiceFoundation.protocolVersion else {
            throw PrivilegedOperationWireError.unsupportedProtocol
        }
        switch action {
        case .create:
            guard payload != nil, requestID == nil else { throw PrivilegedOperationWireError.invalidShape }
        case .status, .cancel:
            guard payload == nil, requestID != nil else { throw PrivilegedOperationWireError.invalidShape }
        }
    }
}

public enum PrivilegedOperationWireError: Error, Equatable, Sendable {
    case oversizedFrame
    case incompleteFrame
    case malformedFrame
    case unsupportedProtocol
    case invalidShape
}

public struct PrivilegedOperationWireResponse: Codable, Sendable {
    public let protocolVersion: Int
    public let requestID: PrivilegedOperationRequestID?
    public let state: PrivilegedOperationState?
    public let result: PrivilegedOperationSafeResult?
    public let errorCode: String?

    public init(requestID: PrivilegedOperationRequestID? = nil, state: PrivilegedOperationState? = nil,
                result: PrivilegedOperationSafeResult? = nil, errorCode: String? = nil) {
        protocolVersion = PrivilegedServiceFoundation.protocolVersion
        self.requestID = requestID
        self.state = state
        self.result = result
        self.errorCode = errorCode
    }
}

public enum PrivilegedOperationFrameCodec {
    public static let maximumPayloadBytes = 64 * 1024

    public static func encode(_ request: PrivilegedOperationWireRequest) throws -> Data {
        try request.validate()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let payload = try encoder.encode(request)
        guard payload.count <= maximumPayloadBytes else { throw PrivilegedOperationWireError.oversizedFrame }
        var length = UInt32(payload.count).bigEndian
        var frame = Data(bytes: &length, count: MemoryLayout<UInt32>.size)
        frame.append(payload)
        return frame
    }

    public static func encodeResponse(_ response: PrivilegedOperationWireResponse) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let payload = try encoder.encode(response)
        guard payload.count <= maximumPayloadBytes else { throw PrivilegedOperationWireError.oversizedFrame }
        var length = UInt32(payload.count).bigEndian
        var frame = Data(bytes: &length, count: MemoryLayout<UInt32>.size)
        frame.append(payload)
        return frame
    }

    public static func decode(_ frame: Data) throws -> PrivilegedOperationWireRequest {
        guard frame.count >= MemoryLayout<UInt32>.size else { throw PrivilegedOperationWireError.incompleteFrame }
        let length = frame.prefix(MemoryLayout<UInt32>.size).withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
        guard length <= maximumPayloadBytes else { throw PrivilegedOperationWireError.oversizedFrame }
        guard frame.count == Int(length) + MemoryLayout<UInt32>.size else { throw PrivilegedOperationWireError.incompleteFrame }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let request = try? decoder.decode(PrivilegedOperationWireRequest.self, from: frame.dropFirst(4)) else {
            throw PrivilegedOperationWireError.malformedFrame
        }
        try request.validate()
        return request
    }
}
