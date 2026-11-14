// swift-tools-version: 6.2
import PackageDescription

let strictSwiftSettings: [SwiftSetting] = [.swiftLanguageMode(.v6), .treatAllWarnings(as: .error)]
let strictCSettings: [CSetting] = [.treatAllWarnings(as: .error)]
let vendoredTreeSitterCSettings: [CSetting] = strictCSettings + [.disableWarning("shorten-64-to-32")]
let frameworksBesideTestBundle: [LinkerSetting] = [
  .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@loader_path/../../.."], .when(platforms: [.macOS]))
]

let package = Package(
  name: "CodevisorKit",
  defaultLocalization: "en",
  platforms: [.macOS("26.0"), .iOS("26.0")],
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
    .library(name: "SimulatorPane", targets: ["SimulatorPane"]),
    .library(name: "ScreenSharingPane", targets: ["ScreenSharingPane"]),
    .library(name: "Autocomplete", targets: ["Autocomplete"]),
    .library(name: "ScreenSharing", targets: ["ScreenSharing"]),
    .library(name: "ScreenSharingV2", targets: ["ScreenSharingV2"]),
    .library(name: "ScreenSharingConnection", targets: ["ScreenSharingConnection"]),
    .library(name: "CodevisorTestSupport", targets: ["CodevisorTestSupport"]),
  ],
  dependencies: [
    .package(url: "https://github.com/PostHog/posthog-ios.git", exact: "3.59.3"),
    .package(url: "https://github.com/pointfreeco/swift-composable-architecture.git", exact: "1.26.2"),
    .package(url: "https://github.com/pointfreeco/swift-concurrency-extras.git", exact: "1.4.1"),
    .package(url: "https://github.com/rive-app/rive-ios.git", exact: "6.29.0"),
  ],
  targets: [
    .systemLibrary(name: "CZlib", path: "ScreenSharing/CZlib"),
    .target(
      name: "ScreenSharing",
      dependencies: ["CZlib"],
      path: "ScreenSharing/Sources/ScreenSharing",
      swiftSettings: strictSwiftSettings
    ),
    .target(
      name: "ScreenSharingV2", dependencies: ["ScreenSharing", "CodevisorClient", "CodevisorNet"],
      path: "ScreenSharing/Sources/ScreenSharingV2", swiftSettings: strictSwiftSettings),
    .testTarget(
      name: "ScreenSharingV2Tests", dependencies: ["ScreenSharingV2", "CodevisorNet", "CodevisorTestSupport"],
      path: "ScreenSharing/Tests/ScreenSharingV2Tests", swiftSettings: strictSwiftSettings),
    .target(
      name: "ScreenSharingConnection", dependencies: ["ScreenSharing", "ScreenSharingV2", "CodevisorClient"],
      path: "ScreenSharingConnection/Sources/ScreenSharingConnection", swiftSettings: strictSwiftSettings),
    .testTarget(
      name: "ScreenSharingConnectionTests",
      dependencies: ["ScreenSharingConnection", "ScreenSharingTesting", "CodevisorClient", "CodevisorTestSupport"],
      path: "ScreenSharingConnection/Tests/ScreenSharingConnectionTests", swiftSettings: strictSwiftSettings),
    .target(
      name: "ScreenSharingBench",
      path: "ScreenSharing/Sources/ScreenSharingBench",
      swiftSettings: strictSwiftSettings
    ),
    .target(
      name: "ScreenSharingBenchScenes",
      dependencies: ["ScreenSharingBench"],
      path: "ScreenSharing/Sources/ScreenSharingBenchScenes",
      swiftSettings: strictSwiftSettings
    ),
    .executableTarget(
      name: "CodevisorBench",
      dependencies: [
        "ScreenSharing", "ScreenSharingV2", "ScreenSharingBench", "ScreenSharingBenchScenes", "CGVirtualDisplayPrivate",
        "CodevisorNet",
      ],
      path: "ScreenSharing/Sources/CodevisorBench",
      swiftSettings: strictSwiftSettings
    ),
    .target(
      name: "ScreenSharingTesting",
      dependencies: ["ScreenSharing", "ScreenSharingBench"],
      path: "ScreenSharing/Sources/ScreenSharingTesting",
      swiftSettings: strictSwiftSettings
    ),
    .testTarget(
      name: "ScreenSharingTests",
      dependencies: ["ScreenSharing", "ScreenSharingTesting", "CodevisorTestSupport"],
      path: "ScreenSharing/Tests/ScreenSharingTests",
      resources: [.copy("RFB/Fixtures")],
      swiftSettings: strictSwiftSettings
    ),
    .testTarget(
      name: "ScreenSharingBenchTests",
      dependencies: ["ScreenSharingBench"],
      path: "ScreenSharing/Tests/ScreenSharingBenchTests",
      resources: [.copy("Report/Fixtures")],
      swiftSettings: strictSwiftSettings
    ),
    .testTarget(
      name: "ScreenSharingBenchScenesTests",
      dependencies: ["ScreenSharingBench", "ScreenSharingBenchScenes"],
      path: "ScreenSharing/Tests/ScreenSharingBenchScenesTests",
      swiftSettings: strictSwiftSettings
    ),
    .testTarget(
      name: "CodevisorBenchTests",
      dependencies: ["CodevisorBench"],
      path: "ScreenSharing/Tests/CodevisorBenchTests",
      swiftSettings: strictSwiftSettings
    ),
    .target(name: "CodevisorTestSupport", path: "TestSupport", swiftSettings: strictSwiftSettings),
    .testTarget(
      name: "CodevisorTestSupportTests",
      dependencies: ["CodevisorTestSupport"],
      path: "TestSupportTests",
      swiftSettings: strictSwiftSettings
    ),
    .target(
      name: "CGVirtualDisplayPrivate", path: "CGVirtualDisplayPrivate", publicHeadersPath: "include",
      cSettings: strictCSettings, linkerSettings: [.linkedFramework("CoreGraphics")]),
    .binaryTarget(name: "CodevisorNetFFI", path: "Frameworks/CodevisorNetFFI.xcframework"),
    .binaryTarget(
      name: "Sentry",
      url: "https://github.com/getsentry/sentry-cocoa/releases/download/9.23.0/Sentry.xcframework.zip",
      checksum: "e16f1fb6333f572e980be28d2a9e1ea20a08c2c91b7901d612ff6cee2af697cf"
    ),
    .target(
      name: "CodevisorNet",
      dependencies: ["CodevisorNetFFI"],
      path: "CodevisorNet/Sources/CodevisorNet",
      swiftSettings: [.swiftLanguageMode(.v5)],
      linkerSettings: [
        .linkedFramework("SystemConfiguration"),
        .linkedFramework("Network"),
        .linkedFramework("Security"),
        .linkedFramework("CoreWLAN", .when(platforms: [.macOS])),
      ]
    ),
    .target(
      name: "CodevisorTheming",
      path: "CodevisorTheming/Sources/CodevisorTheming",
      resources: [.copy("Resources/Themes")],
      swiftSettings: strictSwiftSettings
    ),
    .testTarget(
      name: "CodevisorThemingTests",
      dependencies: ["CodevisorTheming"],
      path: "CodevisorTheming/Tests/CodevisorThemingTests",
      swiftSettings: strictSwiftSettings
    ),

    .target(
      name: "ACPKit",
      path: "ACPKit/Sources/ACPKit",
      swiftSettings: strictSwiftSettings
    ),
    .testTarget(
      name: "ACPKitTests",
      dependencies: ["ACPKit"],
      path: "ACPKit/Tests/ACPKitTests",
      swiftSettings: strictSwiftSettings
    ),

    .target(
      name: "CMD4C",
      path: "StreamMarkdown/Vendor/CMD4C",
      publicHeadersPath: "include",
      cSettings: strictCSettings
    ),
    .target(
      name: "MarkdownCore",
      dependencies: ["CMD4C"],
      path: "MarkdownCore/Sources/MarkdownCore",
      swiftSettings: strictSwiftSettings
    ),
    .target(name: "DefaultBrowser", path: "DefaultBrowser/Sources/DefaultBrowser", swiftSettings: strictSwiftSettings),
    .target(
      name: "StreamMarkdown",
      dependencies: ["MarkdownCore", "DefaultBrowser"],
      path: "StreamMarkdown/Sources/StreamMarkdown",
      swiftSettings: strictSwiftSettings
    ),
    .testTarget(
      name: "StreamMarkdownTests",
      dependencies: ["CodevisorTestSupport", "StreamMarkdown"],
      path: "StreamMarkdown/Tests/StreamMarkdownTests",
      swiftSettings: strictSwiftSettings
    ),

    .target(
      name: "CTreeSitter",
      path: "CodeHighlighter/Vendor/runtime",
      sources: ["lib/src/lib.c"],
      publicHeadersPath: "lib/include",
      cSettings: vendoredTreeSitterCSettings + [.headerSearchPath("lib/src")]
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
      cSettings: vendoredTreeSitterCSettings + [.headerSearchPath("typescript/typescript/src")]
    ),
    .target(
      name: "CodeHighlighter",
      dependencies: ["CTreeSitter", "CodeHighlighterGrammars"],
      path: "CodeHighlighter",
      exclude: ["Vendor", "Tests", "README.md"],
      sources: ["Sources/CodeHighlighter"],
      resources: [.copy("Resources/Queries"), .copy("Resources/ThirdPartyNotices.txt")],
      swiftSettings: strictSwiftSettings
    ),
    .testTarget(
      name: "CodeHighlighterTests",
      dependencies: ["CodeHighlighter", "CodevisorTheming"],
      path: "CodeHighlighter/Tests/CodeHighlighterTests",
      swiftSettings: strictSwiftSettings
    ),

    .target(
      name: "CodevisorProtocol",
      dependencies: ["ACPKit"],
      path: "CodevisorProtocol/Sources/CodevisorProtocol",
      swiftSettings: strictSwiftSettings
    ),
    .testTarget(
      name: "CodevisorProtocolTests",
      dependencies: [
        "CodevisorProtocol",
        "ACPKit",
      ],
      path: "CodevisorProtocol/Tests/CodevisorProtocolTests",
      swiftSettings: strictSwiftSettings
    ),

    .target(
      name: "TranscriptKit",
      dependencies: [
        "ACPKit",
        "CodevisorProtocol",
        "MarkdownCore",
      ],
      path: "TranscriptKit/Sources/TranscriptKit",
      swiftSettings: strictSwiftSettings
    ),
    .testTarget(
      name: "TranscriptKitTests",
      dependencies: [
        "CodevisorTestSupport",
        "TranscriptKit",
        "ACPKit",
      ],
      path: "TranscriptKit/Tests/TranscriptKitTests",
      swiftSettings: strictSwiftSettings
    ),

    .target(
      name: "CodevisorClient",
      dependencies: [
        "ACPKit",
        "CodevisorProtocol",
        "TranscriptKit",
      ],
      path: "CodevisorClient/Sources/CodevisorClient",
      swiftSettings: strictSwiftSettings,
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
      swiftSettings: strictSwiftSettings
    ),

    .target(
      name: "CodevisorCloud",
      dependencies: [
        "ACPKit",
        "CodevisorProtocol",
        "CodevisorClient",
        "CodevisorNet",
      ],
      path: "CodevisorCloud/Sources/CodevisorCloud",
      swiftSettings: strictSwiftSettings,
      linkerSettings: [
        .linkedFramework("Security")
      ]
    ),
    .testTarget(
      name: "CodevisorCloudTests",
      dependencies: [
        .product(name: "ConcurrencyExtras", package: "swift-concurrency-extras"),
        "CodevisorTestSupport",
        "CodevisorCloud",
        "CodevisorClient",
        "ACPKit",
      ],
      path: "CodevisorCloud/Tests/CodevisorCloudTests",
      swiftSettings: strictSwiftSettings
    ),

    .target(
      name: "CodevisorCore",
      dependencies: [
        "ACPKit",
        "CodevisorProtocol",
        "TranscriptKit",
        "CodevisorClient",
        "CodevisorCloud",
        "CodevisorNet",
      ],
      path: "CodevisorCore/Sources/CodevisorCore",
      swiftSettings: strictSwiftSettings,
      linkerSettings: [
        .linkedLibrary("sqlite3"),
        .linkedLibrary("c++"),
        .linkedFramework("Security"),
      ]
    ),
    .testTarget(
      name: "CodevisorCoreTests",
      dependencies: [
        .product(name: "ConcurrencyExtras", package: "swift-concurrency-extras"),
        "CodevisorTestSupport",
        "CodevisorCore",
        "ACPKit",
      ],
      path: "CodevisorCore/Tests/CodevisorCoreTests",
      swiftSettings: strictSwiftSettings
    ),

    .target(
      name: "CodevisorCoreMac",
      dependencies: [
        "CodevisorCore", "ScreenSharing", "ScreenSharingV2", "CodevisorNet",
        "CGVirtualDisplayPrivate", .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
        .product(name: "PostHog", package: "posthog-ios"), "Sentry",
      ],
      path: "CodevisorCoreMac/Sources/CodevisorCoreMac",
      swiftSettings: strictSwiftSettings
    ),
    .target(
      name: "SimulatorPane",
      dependencies: [
        "Autocomplete", "CodevisorCore", "CodevisorUI", "ScreenSharing", "ScreenSharingV2",
      ],
      path: "SimulatorPane/Sources/SimulatorPane",
      swiftSettings: strictSwiftSettings
    ),
    .testTarget(
      name: "SimulatorPaneTests",
      dependencies: ["SimulatorPane", "CodevisorTestSupport"],
      path: "SimulatorPane/Tests/SimulatorPaneTests",
      swiftSettings: strictSwiftSettings,
      linkerSettings: frameworksBesideTestBundle
    ),
    .target(
      name: "ScreenSharingPane",
      dependencies: ["CodevisorCore", "ScreenSharing", "ScreenSharingV2"],
      path: "ScreenSharingPane/Sources/ScreenSharingPane",
      swiftSettings: strictSwiftSettings
    ),
    .testTarget(
      name: "ScreenSharingPaneTests",
      dependencies: ["ScreenSharingPane", "ScreenSharingV2", "CodevisorNet", "CodevisorTestSupport"],
      path: "ScreenSharingPane/Tests/ScreenSharingPaneTests",
      swiftSettings: strictSwiftSettings,
      linkerSettings: frameworksBesideTestBundle
    ),
    .target(
      name: "CodevisorUI",
      dependencies: [
        "CodevisorCore", "CodevisorTheming", "StreamMarkdown", "DefaultBrowser", "CodeHighlighter", "TranscriptKit",
        "Autocomplete",
        .product(name: "RiveRuntime", package: "rive-ios"),
      ],
      path: "CodevisorUI/Sources/CodevisorUI",
      resources: [
        .copy("Resources/plugin-bridge.js"), .copy("Resources/BrowserRouting"),
        .copy("Resources/browser-navigation.js"),
        .process("Resources/FileIcons.xcassets"), .copy("Resources/FileIcons"),
        .process("Resources/Symbols.xcassets"), .process("Resources/MascotSymbols.xcassets"),
        .copy("Resources/Octicons-LICENSE.txt"),
      ],
      swiftSettings: strictSwiftSettings
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
      swiftSettings: strictSwiftSettings,
      linkerSettings: frameworksBesideTestBundle
    ),

    .target(
      name: "Autocomplete",
      path: "Autocomplete/Sources/Autocomplete",
      resources: [.process("Resources")],
      swiftSettings: strictSwiftSettings
    ),
    .testTarget(
      name: "AutocompleteTests",
      dependencies: ["Autocomplete", "CodevisorTestSupport"],
      path: "Autocomplete/Tests/AutocompleteTests",
      swiftSettings: strictSwiftSettings
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
        "Sentry",
      ],
      path: "CodevisorCoreMac/Tests/CodevisorCoreMacTests",
      swiftSettings: strictSwiftSettings,
      linkerSettings: frameworksBesideTestBundle
    ),

    .target(
      name: "TranscriptSurface",
      dependencies: [
        "CodevisorCore",
        "CodevisorUI",
        "CodevisorTheming",
        "StreamMarkdown",
        "MarkdownCore",
        "TranscriptKit",
      ],
      path: "TranscriptSurface/Sources/TranscriptSurface",
      exclude: [
        "AssistantTurnView.swift",
        "ConversationItemView.swift",
        "TranscriptItemsView.swift",
        "TranscriptRowLeaves+macOS.swift",
      ],
      swiftSettings: [.swiftLanguageMode(.v5), .defaultIsolation(MainActor.self), .treatAllWarnings(as: .error)]
    ),
    .testTarget(
      name: "TranscriptSurfaceTests",
      dependencies: ["TranscriptSurface", "CodevisorTestSupport"],
      path: "TranscriptSurface/Tests/TranscriptSurfaceTests",
      swiftSettings: [.treatAllWarnings(as: .error)],
      linkerSettings: frameworksBesideTestBundle
    ),
  ]
)
