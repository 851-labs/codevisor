// swift-tools-version: 6.0
import PackageDescription

// The standalone screen-sharing diagnostic app: two peers in one process over
// a loopback signaling exchange, with the measurement and recovery experiments
// described in packages/swift/CodevisorScreenSharing/README.md. Never shipped.
let package = Package(
  name: "ScreenSharingProbe",
  platforms: [.macOS("26.0")],
  products: [
    .executable(name: "screen-sharing-probe", targets: ["ScreenSharingProbe"])
  ],
  dependencies: [
    .package(name: "CodevisorKit", path: "../../packages/swift")
  ],
  targets: [
    .executableTarget(
      name: "ScreenSharingProbe",
      dependencies: [
        .product(name: "CodevisorScreenSharing", package: "CodevisorKit"),
        .product(name: "CodevisorClient", package: "CodevisorKit"),
        .product(name: "ScreenSharingDiagnostics", package: "CodevisorKit"),
      ],
      swiftSettings: [.swiftLanguageMode(.v6)]
    )
  ]
)
