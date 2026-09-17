// Exercise the production UIKit transcript with fixture rows and no app/server.
// Stage the app-owned surface just as the macOS transcript harness does.
import { cp, mkdir, readdir, realpath, rm, writeFile } from "node:fs/promises"
import { join } from "node:path"
import { fileURLToPath } from "node:url"

import { developmentLayout } from "./dev-layout.ts"
import { requireIOSSimulator } from "./ios-simulator-state.ts"
import { runXcodebuild } from "./xcodebuild.ts"

const root = await realpath(fileURLToPath(new URL("..", import.meta.url)))
const simulator = await requireIOSSimulator(root)
console.log(`  device:    ${simulator.name} (${simulator.runtime}) ${simulator.udid}`)
const harness = join(root, "tmp/ios-transcript-tests")
const sources = join(harness, "Sources/TranscriptSurface")
await rm(join(harness, "Sources"), { recursive: true, force: true })
await rm(join(harness, "Tests"), { recursive: true, force: true })
await mkdir(sources, { recursive: true })
const transcript = join(root, "apps/ios/Codevisor/Features/Session/Transcript")
await Promise.all(
  (await readdir(transcript))
    .filter((name) => name.endsWith(".swift") && name !== "TranscriptRowLeaves+iOS.swift")
    .map((name) => cp(join(transcript, name), join(sources, name)))
)
await cp(
  join(root, "apps/ios/Codevisor/Diagnostics/IOSNavigationDiagnostics.swift"),
  join(sources, "IOSNavigationDiagnostics.swift")
)
await cp(
  join(root, "apps/ios/Codevisor/Features/Session/NewChat/ChatSurfaceBackground.swift"),
  join(sources, "ChatSurfaceBackground.swift")
)
await cp(join(root, "apps/ios/TranscriptTests"), join(harness, "Tests/TranscriptSurfaceTests"), {
  recursive: true
})
await writeFile(
  join(harness, "Package.swift"),
  `// swift-tools-version: 6.2
import PackageDescription
let package = Package(
  name: "IOSTranscriptTests",
  platforms: [.iOS("26.0")],
  products: [.library(name: "TranscriptSurface", targets: ["TranscriptSurface"])],
  dependencies: [.package(path: "../../packages/swift")],
  targets: [
    .target(
      name: "TranscriptSurface",
      dependencies: [${["CodevisorCore", "CodevisorUI", "StreamMarkdown", "TranscriptKit"]
        .map((name) => `.product(name: "${name}", package: "swift")`)
        .join(", ")}],
      swiftSettings: [.swiftLanguageMode(.v5), .defaultIsolation(MainActor.self)]
    ),
    .testTarget(name: "TranscriptSurfaceTests", dependencies: ["TranscriptSurface"])
  ]
)
`
)
await runXcodebuild(
  harness,
  "ios",
  [
    "-scheme",
    "IOSTranscriptTests",
    "-destination",
    `platform=iOS Simulator,id=${simulator.udid}`,
    ...process.argv.slice(2),
    "test"
  ],
  { layout: developmentLayout(root) }
)
