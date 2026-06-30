// swift-tools-version: 6.0
import PackageDescription

// Umbrella package exposing the three HerdMan libraries as a single local
// Swift package, so the app links one package reference. Each target reuses the
// per-module folder layout under Packages/<Module>/.
let package = Package(
    name: "HerdManKit",
    platforms: [
        .macOS("26.0")
    ],
    products: [
        .library(name: "ACPKit", targets: ["ACPKit"]),
        .library(name: "ACPAgents", targets: ["ACPAgents"]),
        .library(name: "StreamMarkdown", targets: ["StreamMarkdown"]),
        .library(name: "HerdManCore", targets: ["HerdManCore"])
    ],
    targets: [
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

        // MARK: ACPAgents
        .target(
            name: "ACPAgents",
            dependencies: ["ACPKit"],
            path: "ACPAgents/Sources/ACPAgents",
            resources: [.copy("Resources/registry-fallback.json")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "ACPAgentsTests",
            dependencies: ["ACPAgents", "ACPKit"],
            path: "ACPAgents/Tests/ACPAgentsTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        // MARK: StreamMarkdown
        .target(
            name: "StreamMarkdown",
            path: "StreamMarkdown/Sources/StreamMarkdown",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "StreamMarkdownTests",
            dependencies: ["StreamMarkdown"],
            path: "StreamMarkdown/Tests/StreamMarkdownTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        // MARK: HerdManCore (app logic: models, repositories, DI, view models)
        .target(
            name: "HerdManCore",
            dependencies: ["ACPKit", "ACPAgents"],
            path: "HerdManCore/Sources/HerdManCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "HerdManCoreTests",
            dependencies: ["HerdManCore", "ACPKit", "ACPAgents"],
            path: "HerdManCore/Tests/HerdManCoreTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
