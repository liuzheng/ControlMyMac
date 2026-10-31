// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ControlMyMac",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ControlMyMacCore", targets: ["ControlMyMacCore"]),
        .executable(name: "ControlMyMac", targets: ["ControlMyMac"]),
        .executable(name: "ControlMyMacBroker", targets: ["ControlMyMacBroker"]),
        .executable(name: "ControlMyMacPrivilegedHelper", targets: ["ControlMyMacPrivilegedHelper"]),
    ],
    targets: [
        .target(name: "ControlMyMacCore"),
        .executableTarget(name: "ControlMyMac", dependencies: ["ControlMyMacCore"]),
        .executableTarget(name: "ControlMyMacBroker", dependencies: ["ControlMyMacCore"]),
        .executableTarget(name: "ControlMyMacPrivilegedHelper", dependencies: ["ControlMyMacCore"]),
        .testTarget(name: "ControlMyMacCoreTests", dependencies: ["ControlMyMacCore"]),
    ]
)
