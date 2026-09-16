// swift-tools-version: 6.0
import PackageDescription

// The screen-sharing development tools, never shipped: the two-Mac rig and, as the
// `probe` subcommand, the single-process diagnostic. A consumer of the media package.
// See docs/plans/screen-sharing-rig.md and README.md.
let package = Package(
  name: "ScreenSharingRig",
  platforms: [.macOS("26.0")],
  products: [
    .executable(name: "screen-sharing-rig", targets: ["ScreenSharingRig"])
  ],
  dependencies: [
    .package(name: "CodevisorKit", path: "../../packages/swift")
  ],
  targets: [
    .target(
      name: "ScreenSharingRigKit",
      dependencies: [
        .product(name: "CodevisorScreenSharing", package: "CodevisorKit"),
        .product(name: "ScreenSharingDiagnostics", package: "CodevisorKit"),
      ],
      swiftSettings: [.swiftLanguageMode(.v6)]
    ),
    .executableTarget(
      name: "ScreenSharingRig",
      dependencies: [
        "ScreenSharingRigKit", "CGVirtualDisplayPrivate",
        .product(name: "CodevisorClient", package: "CodevisorKit"),
        .product(name: "CodevisorScreenSharing", package: "CodevisorKit"),
        .product(name: "ScreenSharingDiagnostics", package: "CodevisorKit"),
        .product(name: "ScreenSharingHostInput", package: "CodevisorKit"),
      ],
      swiftSettings: [.swiftLanguageMode(.v6)]
    ),
    // Private CoreGraphics virtual-display declarations; rig only, see the header.
    .target(
      name: "CGVirtualDisplayPrivate",
      publicHeadersPath: "include",
      linkerSettings: [.linkedFramework("CoreGraphics")]
    ),
    .testTarget(
      name: "ScreenSharingRigKitTests",
      dependencies: ["ScreenSharingRigKit", .product(name: "CodevisorTestSupport", package: "CodevisorKit")],
      swiftSettings: [.swiftLanguageMode(.v6)],
      // SwiftPM's macOS test bundle loader needs the sibling binary framework.
      linkerSettings: [
        .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@loader_path/../../.."], .when(platforms: [.macOS]))
      ]
    ),
  ]
)
