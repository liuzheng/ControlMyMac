import Foundation

/// Constants shared by the foreground app, user broker, and privileged helper.
/// The live registration path remains disabled until a signed local deployment
/// passes the ServiceManagement integration validation.
public enum PrivilegedServiceFoundation {
    public static let protocolVersion = 1
    public static let brokerLabel = "com.liuzheng.controlmymac.privileged-operation-broker"
    public static let helperLabel = "com.liuzheng.controlmymac.privileged-operation-helper"
    public static let brokerIssuer = "com.liuzheng.controlmymac.operation-broker"
    public static let helperAudience = "com.liuzheng.controlmymac.privileged-helper"
}

public struct PrivilegedSigningConfiguration: Equatable, Sendable {
    public let expectedTeamID: String
    public let registrationEnabled: Bool

    public init(expectedTeamID: String, registrationEnabled: Bool) {
        self.expectedTeamID = expectedTeamID
        self.registrationEnabled = registrationEnabled
    }

    /// The local-development default deliberately cannot register a helper.
    /// Production registration is only enabled by an explicitly validated
    /// Apple Development signing configuration.
    public static func current(environment: [String: String] = ProcessInfo.processInfo.environment) -> Self {
        let teamID = environment["CONTROLMYMAC_PRIVILEGED_TEAM_ID"] ?? ""
        let enabled = environment["CONTROLMYMAC_PRIVILEGED_REGISTRATION"] == "1" && !teamID.isEmpty
        return Self(expectedTeamID: teamID, registrationEnabled: enabled)
    }

    public func validate(_ identity: PrivilegedCodeIdentity) -> PrivilegedSigningDiagnostic? {
        guard registrationEnabled else { return .registrationDisabled }
        guard !identity.isAdHoc else { return .adHocSignature }
        guard !identity.isRevoked else { return .revokedIdentity }
        guard identity.teamID == expectedTeamID else { return .teamIDMismatch }
        return nil
    }
}

public struct PrivilegedCodeIdentity: Equatable, Sendable {
    public let teamID: String?
    public let isAdHoc: Bool
    public let isRevoked: Bool

    public init(teamID: String?, isAdHoc: Bool, isRevoked: Bool) {
        self.teamID = teamID
        self.isAdHoc = isAdHoc
        self.isRevoked = isRevoked
    }
}

public enum PrivilegedSigningDiagnostic: String, Codable, Equatable, Sendable, Error {
    case registrationDisabled = "privileged_registration_disabled"
    case adHocSignature = "privileged_ad_hoc_signature"
    case revokedIdentity = "privileged_signing_identity_revoked"
    case teamIDMismatch = "privileged_team_id_mismatch"
}

public struct PrivilegedServiceHealthRequest: Codable, Equatable, Sendable {
    public let protocolVersion: Int
    public let component: Component

    public enum Component: String, Codable, Sendable {
        case broker
        case helper
    }

    public init(protocolVersion: Int = PrivilegedServiceFoundation.protocolVersion, component: Component) {
        self.protocolVersion = protocolVersion
        self.component = component
    }
}

public struct PrivilegedServiceHealthResponse: Codable, Equatable, Sendable {
    public let protocolVersion: Int
    public let component: PrivilegedServiceHealthRequest.Component
    public let state: State
    public let diagnostic: PrivilegedSigningDiagnostic?

    public enum State: String, Codable, Sendable {
        case ready
        case disabled
        case incompatible
    }

    public init(protocolVersion: Int, component: PrivilegedServiceHealthRequest.Component, state: State,
                diagnostic: PrivilegedSigningDiagnostic? = nil) {
        self.protocolVersion = protocolVersion
        self.component = component
        self.state = state
        self.diagnostic = diagnostic
    }
}

public enum PrivilegedServiceHealth {
    public static func respond(to request: PrivilegedServiceHealthRequest,
                               signing: PrivilegedSigningConfiguration) -> PrivilegedServiceHealthResponse {
        guard request.protocolVersion == PrivilegedServiceFoundation.protocolVersion else {
            return PrivilegedServiceHealthResponse(
                protocolVersion: PrivilegedServiceFoundation.protocolVersion,
                component: request.component,
                state: .incompatible
            )
        }
        guard signing.registrationEnabled else {
            return PrivilegedServiceHealthResponse(
                protocolVersion: PrivilegedServiceFoundation.protocolVersion,
                component: request.component,
                state: .disabled,
                diagnostic: .registrationDisabled
            )
        }
        return PrivilegedServiceHealthResponse(
            protocolVersion: PrivilegedServiceFoundation.protocolVersion,
            component: request.component,
            state: .ready
        )
    }
}
