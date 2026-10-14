// swift-tools-version: 6.2
import PackageDescription

let strictSwiftSettings: [SwiftSetting] = [.swiftLanguageMode(.v6), .treatAllWarnings(as: .error)]
let strictCSettings: [CSetting] = [.treatAllWarnings(as: .error)]

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
        .product(name: "ScreenSharing", package: "CodevisorKit"),
        .product(name: "ScreenSharingWebRTC", package: "CodevisorKit"),
        "ScreenSharingDiagnostics",
      ],
      swiftSettings: strictSwiftSettings
    ),
    .executableTarget(
      name: "ScreenSharingRig",
      dependencies: [
        "ScreenSharingRigKit", .product(name: "CGVirtualDisplayPrivate", package: "CodevisorKit"),
        .product(name: "CodevisorClient", package: "CodevisorKit"),
        .product(name: "CodevisorCoreMac", package: "CodevisorKit"),
        .product(name: "ScreenSharing", package: "CodevisorKit"),
        .product(name: "ScreenSharingWebRTC", package: "CodevisorKit"),
        .product(name: "ScreenSharingTesting", package: "CodevisorKit"),
        "ScreenSharingDiagnostics",
      ],
      swiftSettings: strictSwiftSettings
    ),
    .target(
      name: "ScreenSharingDiagnostics",
      dependencies: [
        .product(name: "ScreenSharing", package: "CodevisorKit"),
        .product(name: "ScreenSharingWebRTC", package: "CodevisorKit"),
      ],
      swiftSettings: strictSwiftSettings
    ),
    .testTarget(
      name: "ScreenSharingDiagnosticsTests",
      dependencies: ["ScreenSharingDiagnostics", .product(name: "CodevisorTestSupport", package: "CodevisorKit")],
      swiftSettings: strictSwiftSettings,
      linkerSettings: [
        .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@loader_path/../../.."], .when(platforms: [.macOS]))
      ]
    ),
    .testTarget(
      name: "ScreenSharingRigKitTests",
      dependencies: ["ScreenSharingRigKit", .product(name: "CodevisorTestSupport", package: "CodevisorKit")],
      swiftSettings: strictSwiftSettings,
      linkerSettings: [
        .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@loader_path/../../.."], .when(platforms: [.macOS]))
      ]
    ),
  ]
)
