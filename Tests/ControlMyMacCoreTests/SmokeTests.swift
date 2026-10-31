import XCTest
@testable import ControlMyMacCore

final class SmokeTests: XCTestCase {
    func testCoreModuleLoads() {
        XCTAssertEqual(AirflowPaths.label, "com.liuzheng.controlmymac.airflow")
    }
}
