import Foundation

public struct PrivilegedOperationApprovalSummary: Hashable, Sendable {
    public let title: String
    public let description: String
    public let auditClassification: PrivilegedOperationAuditClassification
}

public struct PrivilegedManualTerminalHandoff: Hashable, Sendable {
    public let command: String
    public let summary: PrivilegedOperationApprovalSummary
    public let warning: String
}

public protocol NetworkServiceResolving {
    func serviceName(for interface: String) throws -> String
}

public enum PrivilegedOperationRegistryError: Error, Equatable, Sendable {
    case unsupportedOperation
    case policyViolation(String)
    case unsafeResolvedService
}

/// A closed registry. New operations must be added in source with a profile,
/// validation rules, safe presentation, renderer, and tests; there is no
/// command, executable path, argv, or environment passthrough.
public struct PrivilegedOperationRegistry: Sendable {
    public static let configureEN9MACAddress = "7c:8a:e1:8d:ab:2f"
    public static let configureEN9SearchDomain = "cn1.global.ctrip.com"

    public init() {}

    public func validate(_ payload: PrivilegedOperationPayload) throws {
        guard payload.operationID == .configureEN9,
              payload.registryVersion == PrivilegedServiceFoundation.protocolVersion,
              case .configureEN9(let parameters) = payload.parameters else {
            throw PrivilegedOperationRegistryError.unsupportedOperation
        }
        guard parameters.interface == "en9" else { throw PrivilegedOperationRegistryError.policyViolation("interface") }
        guard parameters.macAddress == Self.configureEN9MACAddress else { throw PrivilegedOperationRegistryError.policyViolation("mac_address") }
        guard parameters.searchDomain == Self.configureEN9SearchDomain else { throw PrivilegedOperationRegistryError.policyViolation("search_domain") }
    }

    public func approvalSummary(for payload: PrivilegedOperationPayload) throws -> PrivilegedOperationApprovalSummary {
        try validate(payload)
        let defaultTitle = "配置 Ctrip 网络"
        let defaultDescription = "将为 en9 应用已注册的 MAC 地址和 DNS 搜索域。"
        return PrivilegedOperationApprovalSummary(
            title: payload.approval.title ?? defaultTitle,
            description: payload.approval.description ?? defaultDescription,
            auditClassification: .manualTerminalHandoff
        )
    }

    public func manualTerminalHandoff(for payload: PrivilegedOperationPayload,
                                      serviceResolver: NetworkServiceResolving) throws -> PrivilegedManualTerminalHandoff {
        try validate(payload)
        guard case .configureEN9(let parameters) = payload.parameters else {
            throw PrivilegedOperationRegistryError.unsupportedOperation
        }
        let service = try serviceResolver.serviceName(for: parameters.interface)
        guard Self.isSafeServiceName(service) else { throw PrivilegedOperationRegistryError.unsafeResolvedService }
        let command = "sudo /sbin/ifconfig en9 ether \(Self.shellQuote(parameters.macAddress)) && sudo /usr/sbin/networksetup -setsearchdomains \(Self.shellQuote(service)) \(Self.shellQuote(parameters.searchDomain))"
        return PrivilegedManualTerminalHandoff(
            command: command,
            summary: try approvalSummary(for: payload),
            warning: "此命令尚未执行。请在 Terminal 粘贴后使用 sudo 密码完成系统授权。"
        )
    }

    private static func isSafeServiceName(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 128 && !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    }

    private static func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\\"'\\\"'"))'"
    }
}

public struct FixedNetworkServiceResolver: NetworkServiceResolving {
    public let service: String
    public init(service: String) { self.service = service }
    public func serviceName(for interface: String) throws -> String { service }
}
