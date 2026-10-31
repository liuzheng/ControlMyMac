import XCTest
@testable import ControlMyMacCore

final class PrivilegedOperationRegistryTests: XCTestCase {
    private let registry = PrivilegedOperationRegistry()

    private func approvedPayload(macAddress: String = PrivilegedOperationRegistry.configureEN9MACAddress,
                                 searchDomain: String = PrivilegedOperationRegistry.configureEN9SearchDomain) throws -> PrivilegedOperationPayload {
        try PrivilegedOperationPayload(
            operationID: .configureEN9,
            parameters: .configureEN9(try ConfigureEN9Parameters(
                interface: "en9", macAddress: macAddress, searchDomain: searchDomain
            )),
            approval: try .init(title: "配置网络", description: "只应用已注册网络设置")
        )
    }

    func testRegistryOnlyAcceptsCompiledConfigureEN9Policy() throws {
        XCTAssertNoThrow(try registry.validate(approvedPayload()))
        XCTAssertThrowsError(try registry.validate(approvedPayload(macAddress: "00:00:00:00:00:00")))
        XCTAssertThrowsError(try registry.validate(approvedPayload(searchDomain: "example.com")))
    }

    func testManualHandoffUsesFixedToolsAndQuotedResolvedService() throws {
        let handoff = try registry.manualTerminalHandoff(
            for: approvedPayload(),
            serviceResolver: FixedNetworkServiceResolver(service: "USB Ethernet; echo ignored")
        )

        XCTAssertEqual(handoff.summary.title, "配置网络")
        XCTAssertTrue(handoff.command.hasPrefix("sudo /sbin/ifconfig en9 ether '7c:8a:e1:8d:ab:2f' && sudo /usr/sbin/networksetup -setsearchdomains"))
        XCTAssertTrue(handoff.command.contains("'USB Ethernet; echo ignored'"))
        XCTAssertFalse(handoff.command.contains("/tmp/"))
        XCTAssertFalse(handoff.command.contains("/bin/sh -c"))
    }

    func testRegistryRejectsUnsafeResolvedService() throws {
        XCTAssertThrowsError(try registry.manualTerminalHandoff(
            for: approvedPayload(),
            serviceResolver: FixedNetworkServiceResolver(service: "safe\nunsafe")
        )) { error in
            XCTAssertEqual(error as? PrivilegedOperationRegistryError, .unsafeResolvedService)
        }
    }
}
