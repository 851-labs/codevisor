// Exercise the production AppKit transcript without booting the full app or
// its server. Stage sources in tmp so SwiftPM can test the app-owned surface.
import { cp, mkdir, readdir, rm, writeFile } from "node:fs/promises"
import { spawnSync } from "node:child_process"
import { fileURLToPath } from "node:url"
import { join } from "node:path"

const root = fileURLToPath(new URL("..", import.meta.url))
const harness = join(root, "tmp/macos-transcript-tests")
const sources = join(harness, "Sources/TranscriptSurface")
const tests = join(harness, "Tests/TranscriptSurfaceTests")
await rm(join(harness, "Sources"), { recursive: true, force: true })
await rm(join(harness, "Tests"), { recursive: true, force: true })
await mkdir(sources, { recursive: true })
const excluded = new Set([
  "AssistantTurnView.swift",
  "ConversationItemView.swift",
  "TranscriptItemsView.swift",
  "TranscriptMarkdownLinkOpener.swift",
  "TranscriptRowLeaves+macOS.swift"
])
const transcript = join(root, "apps/macos/Codevisor/Features/Session/Transcript")
await Promise.all(
  (await readdir(transcript))
    .filter((name) => name.endsWith(".swift") && !excluded.has(name))
    .map((name) => cp(join(transcript, name), join(sources, name)))
)
await cp(join(root, "apps/macos/Tests/Transcript"), tests, { recursive: true })
await writeFile(
  join(harness, "Package.swift"),
  `// swift-tools-version: 6.2
import PackageDescription
let package = Package(
  name: "MacOSTranscriptTests",
  platforms: [.macOS("26.0")],
  dependencies: [.package(path: "../../packages/swift")],
  targets: [
    .target(
      name: "TranscriptSurface",
      dependencies: [${[
        "CodevisorCore",
        "CodevisorUI",
        "CodevisorTheming",
        "StreamMarkdown",
        "MarkdownCore",
        "TranscriptKit"
      ]
        .map((name) => `.product(name: "${name}", package: "swift")`)
        .join(", ")}],
      swiftSettings: [.swiftLanguageMode(.v5), .defaultIsolation(MainActor.self)]
    ),
    .testTarget(name: "TranscriptSurfaceTests", dependencies: ["TranscriptSurface"])
  ]
)
`
)
const result = spawnSync("swift", ["test", "--package-path", harness, ...process.argv.slice(2)], {
  stdio: "inherit"
})
if (result.error) throw result.error
process.exit(result.status ?? 1)
