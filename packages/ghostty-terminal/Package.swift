// swift-tools-version: 6.0
import PackageDescription

// libghostty-spm's GhosttyTerminal UIKit layer (MIT, see
// LICENSE-libghostty-spm), vendored for the iOS app's terminal panes and built
// against the same GhosttyKit.xcframework as the macOS app (produced by
// apps/macos/scripts/build-ghostty.sh; `GhosttyKit.xcframework` here is a
// symlink to it). Local changes are marked CODEVISOR-PATCH; see README.md.
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
