// Exercise the production native editor and focus policy without booting the
// full app or server, following the transcript test harness.
import { cp, mkdir, readFile, rm, writeFile } from "node:fs/promises"
import { spawnSync } from "node:child_process"
import { fileURLToPath } from "node:url"
import { join } from "node:path"

const root = fileURLToPath(new URL("..", import.meta.url))
const harness = join(root, "tmp/macos-composer-tests")
const sources = join(harness, "Sources/ComposerSurface")
await rm(join(harness, "Sources"), { recursive: true, force: true })
await rm(join(harness, "Tests"), { recursive: true, force: true })
await mkdir(sources, { recursive: true })
await mkdir(join(harness, "Sources/CodevisorUI"), { recursive: true })
await cp(
  join(
    root,
    "packages/swift/CodevisorUI/Sources/CodevisorUI/DesignSystem/HoverIconButtonStyle.swift"
  ),
  join(harness, "Sources/CodevisorUI/HoverIconButtonStyle.swift")
)
await cp(
  join(root, "packages/swift/Autocomplete/Sources/Autocomplete"),
  join(harness, "Sources/Autocomplete"),
  {
    recursive: true
  }
)
await Promise.all(
  ["ChatInputEditor.swift", "ComposerKeyboardNavigation.swift", "ComposerKeyboardButton.swift"].map(
    (name) => cp(join(root, "apps/macos/Codevisor/Features/Composer", name), join(sources, name))
  )
)
// The editor's image-paste dependency lives with the attachment UI. Include
// the actual production encoder without pulling in the rest of that screen.
const attachments = await readFile(
  join(root, "apps/macos/Codevisor/Features/Session/AttachmentThumbnailView.swift"),
  "utf8"
)
const encoder = attachments.match(
  /nonisolated func pngData\(from imageData: Data\) -> Data\? \{[^]*?\n\}/
)?.[0]
if (!encoder) throw new Error("Could not locate the production image encoder")
await writeFile(join(sources, "ImageEncoding.swift"), `import AppKit\n${encoder}\n`)
await cp(join(root, "apps/macos/Tests/Composer"), join(harness, "Tests/ComposerSurfaceTests"), {
  recursive: true
})
await writeFile(
  join(harness, "Package.swift"),
  `// swift-tools-version: 6.2
import PackageDescription
let package = Package(
  name: "MacOSComposerTests", defaultLocalization: "en", platforms: [.macOS("26.0")],
  targets: [
    .target(name: "Autocomplete", resources: [.process("Resources")]),
    .target(name: "CodevisorUI"),
    .target(name: "ComposerSurface", dependencies: ["CodevisorUI"], swiftSettings: [.swiftLanguageMode(.v5), .defaultIsolation(MainActor.self)]),
    .testTarget(name: "ComposerSurfaceTests", dependencies: ["ComposerSurface", "Autocomplete", "CodevisorUI"])
  ]
)
`
)
const result = spawnSync("swift", ["test", "--package-path", harness, ...process.argv.slice(2)], {
  stdio: "inherit"
})
if (result.error) throw result.error
process.exit(result.status ?? 1)
