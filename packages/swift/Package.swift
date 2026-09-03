// swift-tools-version: 6.0
import PackageDescription

// Umbrella package exposing the three Codevisor libraries as a single local
// Swift package, so the app links one package reference. Each target reuses the
// per-module folder layout under Packages/<Module>/.
let package = Package(
  name: "CodevisorKit",
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
  ],
  dependencies: [
    .package(url: "https://github.com/PostHog/posthog-ios.git", exact: "3.59.3"),
    .package(url: "https://github.com/getsentry/sentry-cocoa.git", exact: "9.23.0"),
  ],
  targets: [
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
      dependencies: ["StreamMarkdown"],
      path: "StreamMarkdown/Tests/StreamMarkdownTests",
      swiftSettings: [.swiftLanguageMode(.v6)]
    ),

    // MARK: CodeHighlighter (native Swift tokenization and VS Code theme mapping)
    .target(
      name: "CodeHighlighter",
      path: "CodeHighlighter/Sources/CodeHighlighter",
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
      dependencies: ["CodevisorCore"],
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
      ],
      path: "CodevisorUI/Sources/CodevisorUI",
      resources: [.copy("Resources/plugin-bridge.js")],
      swiftSettings: [.swiftLanguageMode(.v6)]
    ),
    .testTarget(
      name: "CodevisorUITests",
      dependencies: [
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
      swiftSettings: [.swiftLanguageMode(.v6)]
    ),
    .testTarget(
      name: "AutocompleteTests",
      dependencies: ["Autocomplete"],
      path: "Autocomplete/Tests/AutocompleteTests",
      swiftSettings: [.swiftLanguageMode(.v6)]
    ),

    .testTarget(
      name: "CodevisorCoreMacTests",
      dependencies: [
        "CodevisorCoreMac",
        "CodevisorCore",
        "ACPKit",
      ],
      path: "CodevisorCoreMac/Tests/CodevisorCoreMacTests",
      swiftSettings: [.swiftLanguageMode(.v6)]
    ),
  ]
)
