import XCTest
@testable import ControlMyMacCore

final class PrivilegedServiceFoundationTests: XCTestCase {
    func testDefaultConfigurationFailsClosed() {
        let configuration = PrivilegedSigningConfiguration.current(environment: [:])
        let response = PrivilegedServiceHealth.respond(
            to: PrivilegedServiceHealthRequest(component: .broker),
            signing: configuration
        )

        XCTAssertFalse(configuration.registrationEnabled)
        XCTAssertEqual(response.state, .disabled)
        XCTAssertEqual(response.diagnostic, .registrationDisabled)
    }

    func testMatchingDevelopmentIdentityCanPassSigningValidation() {
        let configuration = PrivilegedSigningConfiguration(expectedTeamID: "TEAM123", registrationEnabled: true)
        let identity = PrivilegedCodeIdentity(teamID: "TEAM123", isAdHoc: false, isRevoked: false)

        XCTAssertNil(configuration.validate(identity))
    }

    func testAdHocRevokedAndMismatchedIdentitiesFailClosed() {
        let configuration = PrivilegedSigningConfiguration(expectedTeamID: "TEAM123", registrationEnabled: true)

        XCTAssertEqual(configuration.validate(.init(teamID: "TEAM123", isAdHoc: true, isRevoked: false)), .adHocSignature)
        XCTAssertEqual(configuration.validate(.init(teamID: "TEAM123", isAdHoc: false, isRevoked: true)), .revokedIdentity)
        XCTAssertEqual(configuration.validate(.init(teamID: "OTHER", isAdHoc: false, isRevoked: false)), .teamIDMismatch)
    }

    func testHealthRejectsUnknownProtocolVersion() {
        let response = PrivilegedServiceHealth.respond(
            to: PrivilegedServiceHealthRequest(protocolVersion: 99, component: .helper),
            signing: .init(expectedTeamID: "TEAM123", registrationEnabled: true)
        )

        XCTAssertEqual(response.state, .incompatible)
        XCTAssertNil(response.diagnostic)
    }
}
