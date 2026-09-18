// swift-tools-version: 6.0
import PackageDescription

// Umbrella package exposing the three Codevisor libraries as a single local
// Swift package, so the app links one package reference. Each target reuses the
// per-module folder layout under Packages/<Module>/.
let package = Package(
  name: "CodevisorKit",
  defaultLocalization: "en",
  platforms: [
    .macOS("26.0"),
    .iOS("26.0"),
  ],
  products: [
    .library(name: "ACPKit", targets: ["ACPKit"]),
    .library(name: "MarkdownCore", targets: ["MarkdownCore"]),
    .library(name: "StreamMarkdown", targets: ["StreamMarkdown"]),
    .library(name: "CodevisorTheming", targets: ["CodevisorTheming"]),
    .library(name: "CodeHighlighter", targets: ["CodeHighlighter"]),
    .library(name: "CodevisorProtocol", targets: ["CodevisorProtocol"]),
    .library(name: "TranscriptKit", targets: ["TranscriptKit"]),
    .library(name: "CodevisorClient", targets: ["CodevisorClient"]),
    .library(name: "CodevisorCloud", targets: ["CodevisorCloud"]),
    .library(name: "CodevisorCore", targets: ["CodevisorCore"]),
    .library(name: "CodevisorCoreMac", targets: ["CodevisorCoreMac"]),
    .library(name: "CodevisorUI", targets: ["CodevisorUI"]),
    .library(name: "Autocomplete", targets: ["Autocomplete"]),
    // Screen sharing, in three targets: the WebRTC-free engine, the WebRTC peer, and test doubles.
    .library(name: "ScreenSharing", targets: ["ScreenSharing"]),
    .library(name: "ScreenSharingWebRTC", targets: ["ScreenSharingWebRTC"]),
    .library(name: "ScreenSharingTesting", targets: ["ScreenSharingTesting"]),
    .library(name: "CodevisorTestSupport", targets: ["CodevisorTestSupport"]),
  ],
  dependencies: [
    .package(url: "https://github.com/PostHog/posthog-ios.git", exact: "3.59.3"),
    .package(url: "https://github.com/getsentry/sentry-cocoa.git", exact: "9.23.0"),
    .package(url: "https://github.com/851-labs/webrtc.git", exact: "152.0.0-codevisor.1"),
    .package(url: "https://github.com/pointfreeco/swift-composable-architecture.git", exact: "1.26.2"),
  ],
  targets: [
    // MARK: ScreenSharing (the engine, WebRTC-free: session and message contracts, frames and the
    // mailbox, metrics, ScreenCaptureKit capture, VideoToolbox codecs, the Metal renderer, the AppKit
    // viewer surface, host input injection, the RFB protocol and the VNC viewing session. Links CZlib
    // and system frameworks only, so a backend that is not the native WebRTC pipeline, and every test
    // of these parts, never loads the binary framework. See docs/plans/screen-sharing-composable-architecture.md.)
    .systemLibrary(name: "CZlib", path: "ScreenSharing/CZlib"),
    .target(
      name: "ScreenSharing",
      dependencies: ["CZlib"],
      path: "ScreenSharing/Sources/ScreenSharing",
      swiftSettings: [.swiftLanguageMode(.v6)]
    ),
    // The native transport: the WebRTC peer, its data channels, sender and receiver endpoints with
    // their recovery, the codec factory bridging VideoToolbox into WebRTC, and the pinned field
    // trials. The only target that links WebRTC.
    .target(
      name: "ScreenSharingWebRTC",
      dependencies: ["ScreenSharing", .product(name: "WebRTC", package: "WebRTC")],
      path: "ScreenSharing/Sources/ScreenSharingWebRTC",
      resources: [
        .copy("Resources/WebRTC-LICENSE.txt"),
        .copy("Resources/WebRTC-ThirdPartyNotices-macOS.md"),
        .copy("Resources/WebRTC-ThirdPartyNotices-iOS.md"),
      ],
      swiftSettings: [.swiftLanguageMode(.v6)]
    ),
    // Test doubles: the in-process VNC server (scripted handshake, every encoding, a message log)
    // the suites and the rig drive. Never a dependency of a product target.
    .target(
      name: "ScreenSharingTesting",
      dependencies: ["ScreenSharing"],
      path: "ScreenSharing/Sources/ScreenSharingTesting",
      swiftSettings: [.swiftLanguageMode(.v6)]
    ),
    .testTarget(
      name: "ScreenSharingTests",
      dependencies: ["ScreenSharing", "ScreenSharingTesting", "CodevisorTestSupport"],
      path: "ScreenSharing/Tests/ScreenSharingTests",
      swiftSettings: [.swiftLanguageMode(.v6)]
    ),
    .testTarget(
      name: "ScreenSharingWebRTCTests",
      dependencies: ["ScreenSharingWebRTC", "CodevisorTestSupport"],
      path: "ScreenSharing/Tests/ScreenSharingWebRTCTests",
      swiftSettings: [.swiftLanguageMode(.v6)],
      // SwiftPM's macOS test bundle loader needs the sibling binary framework.
      linkerSettings: [
        .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@loader_path/../../.."], .when(platforms: [.macOS]))
      ]
    ),
    .target(name: "CodevisorTestSupport", path: "TestSupport", swiftSettings: [.swiftLanguageMode(.v6)]),
    // MARK: CodevisorTheming (VSCode/Shiki theme parsing, normalization,
    // palette derivation — Foundation-only, no SwiftUI)
    .target(
      name: "CodevisorTheming",
      path: "CodevisorTheming/Sources/CodevisorTheming",
      resources: [.copy("Resources/Themes")],
      swiftSettings: [.swiftLanguageMode(.v6)]
    ),
    .testTarget(
      name: "CodevisorThemingTests",
      dependencies: ["CodevisorTheming"],
      path: "CodevisorTheming/Tests/CodevisorThemingTests",
      swiftSettings: [.swiftLanguageMode(.v6)]
    ),

    // MARK: ACPKit
    .target(
      name: "ACPKit",
      path: "ACPKit/Sources/ACPKit",
      swiftSettings: [.swiftLanguageMode(.v6)]
    ),
    .testTarget(
      name: "ACPKitTests",
      dependencies: ["ACPKit"],
      path: "ACPKit/Tests/ACPKitTests",
      swiftSettings: [.swiftLanguageMode(.v6)]
    ),

    // MARK: StreamMarkdown
    .target(
      name: "CMD4C",
      path: "StreamMarkdown/Vendor/CMD4C",
      publicHeadersPath: "include"
    ),
    .target(
      name: "MarkdownCore",
      dependencies: ["CMD4C"],
      path: "MarkdownCore/Sources/MarkdownCore",
      swiftSettings: [.swiftLanguageMode(.v6)]
    ),
    .target(
      name: "StreamMarkdown",
      dependencies: ["MarkdownCore"],
      path: "StreamMarkdown/Sources/StreamMarkdown",
      swiftSettings: [.swiftLanguageMode(.v6)]
    ),
    .testTarget(
      name: "StreamMarkdownTests",
      dependencies: ["CodevisorTestSupport", "StreamMarkdown"],
      path: "StreamMarkdown/Tests/StreamMarkdownTests",
      swiftSettings: [.swiftLanguageMode(.v6)]
    ),

    // MARK: CodeHighlighter (our Swift bindings over the vendored Tree-sitter C API)
    .target(
      name: "CTreeSitter",
      path: "CodeHighlighter/Vendor/runtime",
      sources: ["lib/src/lib.c"],
      publicHeadersPath: "lib/include",
      cSettings: [.headerSearchPath("lib/src")]
    ),
    .target(
      name: "CodeHighlighterGrammars",
      dependencies: ["CTreeSitter"],
      path: "CodeHighlighter/Vendor",
      sources: [
        "bash/src/parser.c", "bash/src/scanner.c", "c/src/parser.c",
        "cpp/src/parser.c", "cpp/src/scanner.c", "css/src/parser.c", "css/src/scanner.c",
        "diff/src/parser.c", "go/src/parser.c", "html/src/parser.c", "html/src/scanner.c",
        "java/src/parser.c", "javascript/src/parser.c", "javascript/src/scanner.c", "json/src/parser.c",
        "kotlin/src/parser.c", "kotlin/src/scanner.c",
        "markdown/tree-sitter-markdown/src/parser.c", "markdown/tree-sitter-markdown/src/scanner.c",
        "markdown/tree-sitter-markdown-inline/src/parser.c", "markdown/tree-sitter-markdown-inline/src/scanner.c",
        "python/src/parser.c", "python/src/scanner.c", "ruby/src/parser.c", "ruby/src/scanner.c",
        "rust/src/parser.c", "rust/src/scanner.c", "sql/src/parser.c", "sql/src/scanner.c",
        "swift/src/parser.c", "swift/src/scanner.c", "toml/src/parser.c", "toml/src/scanner.c",
        "typescript/typescript/src/parser.c", "typescript/typescript/src/scanner.c",
        "typescript/tsx/src/parser.c", "typescript/tsx/src/scanner.c",
        "yaml/src/parser.c", "yaml/src/scanner.c",
      ],
      publicHeadersPath: "include",
      cSettings: [.headerSearchPath("typescript/typescript/src")]
    ),
    .target(
      name: "CodeHighlighter",
      dependencies: ["CTreeSitter", "CodeHighlighterGrammars"],
      path: "CodeHighlighter",
      exclude: ["Vendor", "Tests", "README.md"],
      sources: ["Sources/CodeHighlighter"],
      resources: [.copy("Resources/Queries"), .copy("Resources/ThirdPartyNotices.txt")],
      swiftSettings: [.swiftLanguageMode(.v6)]
    ),
    .testTarget(
      name: "CodeHighlighterTests",
      dependencies: ["CodeHighlighter", "CodevisorTheming"],
      path: "CodeHighlighter/Tests/CodeHighlighterTests",
      swiftSettings: [.swiftLanguageMode(.v6)]
    ),

    // MARK: CodevisorProtocol (session/project domain models shared across
    // targets — Foundation + ACPKit only)
    .target(
      name: "CodevisorProtocol",
      dependencies: ["ACPKit"],
      path: "CodevisorProtocol/Sources/CodevisorProtocol",
      swiftSettings: [.swiftLanguageMode(.v6)]
    ),
    .testTarget(
      name: "CodevisorProtocolTests",
      dependencies: [
        "CodevisorProtocol",
        "ACPKit",
      ],
      path: "CodevisorProtocol/Tests/CodevisorProtocolTests",
      swiftSettings: [.swiftLanguageMode(.v6)]
    ),

    // MARK: TranscriptKit (transcript reduction, row projection, virtual
    // layout, measurement/pagination gates — no UI framework dependencies)
    .target(
      name: "TranscriptKit",
      dependencies: [
        "ACPKit",
        "CodevisorProtocol",
        "MarkdownCore",
      ],
      path: "TranscriptKit/Sources/TranscriptKit",
      swiftSettings: [.swiftLanguageMode(.v6)]
    ),
    .testTarget(
      name: "TranscriptKitTests",
      dependencies: [
        "CodevisorTestSupport",
        "TranscriptKit",
        "ACPKit",
      ],
      path: "TranscriptKit/Tests/TranscriptKitTests",
      swiftSettings: [.swiftLanguageMode(.v6)]
    ),

    // MARK: CodevisorClient (the Codevisor server's HTTP/WebSocket client,
    // machine credential storage, session transport — no UI dependencies)
    .target(
      name: "CodevisorClient",
      dependencies: [
        "ACPKit",
        "CodevisorProtocol",
        "TranscriptKit",
      ],
      path: "CodevisorClient/Sources/CodevisorClient",
      swiftSettings: [.swiftLanguageMode(.v6)],
      linkerSettings: [
        .linkedFramework("Security")
      ]
    ),
    .testTarget(
      name: "CodevisorClientTests",
      dependencies: [
        "CodevisorTestSupport",
        "CodevisorClient",
        "CodevisorCloud",
        "ACPKit",
        "CodevisorProtocol",
      ],
      path: "CodevisorClient/Tests/CodevisorClientTests",
      swiftSettings: [.swiftLanguageMode(.v6)]
    ),

    // MARK: CodevisorCloud (Codevisor Cloud account, hub connection, and
    // end-to-end encrypted relay transports)
    .target(
      name: "CodevisorCloud",
      dependencies: [
        "ACPKit",
        "CodevisorProtocol",
        "CodevisorClient",
      ],
      path: "CodevisorCloud/Sources/CodevisorCloud",
      swiftSettings: [.swiftLanguageMode(.v6)],
      linkerSettings: [
        .linkedFramework("Security")
      ]
    ),
    .testTarget(
      name: "CodevisorCloudTests",
      dependencies: [
        "CodevisorTestSupport",
        "CodevisorCloud",
        "CodevisorClient",
        "ACPKit",
      ],
      path: "CodevisorCloud/Tests/CodevisorCloudTests",
      swiftSettings: [.swiftLanguageMode(.v6)]
    ),

    // MARK: CodevisorCore (app logic: models, repositories, DI, view models)
    .target(
      name: "CodevisorCore",
      dependencies: [
        "ACPKit",
        "CodevisorProtocol",
        "TranscriptKit",
        "CodevisorClient",
        "CodevisorCloud",
        "CodevisorTheming",
        .product(name: "PostHog", package: "posthog-ios"),
        .product(name: "Sentry", package: "sentry-cocoa"),
      ],
      path: "CodevisorCore/Sources/CodevisorCore",
      swiftSettings: [.swiftLanguageMode(.v6)],
      linkerSettings: [
        .linkedLibrary("sqlite3"),
        .linkedFramework("Security"),
      ]
    ),
    .testTarget(
      name: "CodevisorCoreTests",
      dependencies: [
        "CodevisorTestSupport",
        "CodevisorCore",
        "ACPKit",
        .product(name: "Sentry", package: "sentry-cocoa"),
      ],
      path: "CodevisorCore/Tests/CodevisorCoreTests",
      swiftSettings: [.swiftLanguageMode(.v6)]
    ),

    // MARK: CodevisorCoreMac (macOS-only halves of CodevisorCore: the
    // app-managed local server process, command running, computer use.
    // iOS apps depend on CodevisorCore only; never link this on iOS.)
    .target(
      name: "CodevisorCoreMac",
      dependencies: [
        "CodevisorCore", "ScreenSharing", "ScreenSharingWebRTC",
        .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
      ],
      path: "CodevisorCoreMac/Sources/CodevisorCoreMac",
      swiftSettings: [.swiftLanguageMode(.v6)]
    ),
    // MARK: CodevisorUI (shared SwiftUI: theme tokens, motion, markdown/
    // highlight adapters, transcript environment plumbing — platform-
    // neutral views shared by the macOS and iOS apps)
    .target(
      name: "CodevisorUI",
      dependencies: [
        "CodevisorCore",
        "CodevisorTheming",
        "StreamMarkdown",
        "CodeHighlighter",
        "TranscriptKit",
        "Autocomplete",
      ],
      path: "CodevisorUI/Sources/CodevisorUI",
      resources: [
        .copy("Resources/plugin-bridge.js"), .copy("Resources/BrowserRouting"),
        .copy("Resources/browser-navigation.js"),
        .process("Resources/FileIcons.xcassets"), .copy("Resources/FileIcons"),
      ],
      swiftSettings: [.swiftLanguageMode(.v6)]
    ),
    .testTarget(
      name: "CodevisorUITests",
      dependencies: [
        "CodevisorTestSupport",
        "CodevisorUI",
        "CodevisorClient",
        "ACPKit",
      ],
      path: "CodevisorUI/Tests/CodevisorUITests",
      swiftSettings: [.swiftLanguageMode(.v6)]
    ),

    // MARK: Autocomplete (filterable, keyboard-navigable pickers composed like
    // SwiftUI views: searchable menus, inline popups, command palettes. The
    // state types are platform-neutral; the views are AppKit-hosted SwiftUI.
    // No Codevisor dependencies, so it stays reusable and cheap to build.)
    .target(
      name: "Autocomplete",
      path: "Autocomplete/Sources/Autocomplete",
      resources: [.process("Resources")],
      swiftSettings: [.swiftLanguageMode(.v6)]
    ),
    .testTarget(
      name: "AutocompleteTests",
      dependencies: ["Autocomplete", "CodevisorTestSupport"],
      path: "Autocomplete/Tests/AutocompleteTests",
      swiftSettings: [.swiftLanguageMode(.v6)]
    ),

    .testTarget(
      name: "CodevisorCoreMacTests",
      dependencies: [
        "CodevisorTestSupport",
        "CodevisorCoreMac",
        "CodevisorCore",
        "ACPKit",
        "ScreenSharing",
        "ScreenSharingTesting",
      ],
      path: "CodevisorCoreMac/Tests/CodevisorCoreMacTests",
      swiftSettings: [.swiftLanguageMode(.v6)],
      linkerSettings: [
        .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@loader_path/../../.."], .when(platforms: [.macOS]))
      ]
    ),
  ]
)
