// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "FlowSwitchMac", platforms: [.macOS(.v13)],
    products: [.executable(name: "FlowSwitch", targets: ["FlowSwitch"])],
    targets: [
        .target(name: "FlowModel"),
        .executableTarget(name: "FlowSwitch", dependencies: ["FlowModel"],
                          linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("SystemConfiguration"), .linkedFramework("Security")]),
        .testTarget(name: "FlowModelTests", dependencies: ["FlowModel"])
    ])
