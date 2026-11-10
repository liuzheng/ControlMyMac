// swift-tools-version:5.7
import PackageDescription

let package = Package(
    name: "ControlMyMac",
    platforms: [.macOS(.v12)],
    products: [
        .library(name: "ControlMyMacCore", targets: ["ControlMyMacCore"]),
        .executable(name: "ControlMyMac", targets: ["ControlMyMac"]),
    ],
    targets: [
        .target(name: "ControlMyMacCore"),
        .executableTarget(name: "ControlMyMac", dependencies: ["ControlMyMacCore"]),
        .testTarget(name: "ControlMyMacCoreTests", dependencies: ["ControlMyMacCore"]),
    ]
)
