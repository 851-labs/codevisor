// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "GhosttyTerminal",
  platforms: [.iOS(.v17)],
  products: [
    .library(name: "GhosttyTerminal", targets: ["GhosttyTerminal"])
  ],
  targets: [
    .binaryTarget(name: "GhosttyKit", path: "GhosttyKit.xcframework"),
    .target(
      name: "GhosttyTerminal",
      dependencies: ["GhosttyKit"],
      path: "Sources/Vendor/GhosttyTerminal",
      linkerSettings: [.linkedLibrary("c++")]
    ),
  ]
)
