import XCTest
@testable import ControlMyMacCore

final class MacOSNetworkServiceResolverTests: XCTestCase {
    private let output = """
    (1) Wi-Fi
    (Hardware Port: Wi-Fi, Device: en0)
    (2) Ctrip USB Ethernet
    (Hardware Port: USB 10/100/1000 LAN, Device: en9)
    """

    func testParserFindsServiceForValidatedInterface() {
        XCTAssertEqual(NetworkServiceOrderParser().serviceName(for: "en9", output: output), "Ctrip USB Ethernet")
        XCTAssertNil(NetworkServiceOrderParser().serviceName(for: "en12", output: output))
    }

    func testResolverDoesNotAcceptCallerProvidedServiceName() throws {
        let resolver = MacOSNetworkServiceResolver(command: { self.output })
        XCTAssertEqual(try resolver.serviceName(for: "en9"), "Ctrip USB Ethernet")
    }
}
