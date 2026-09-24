import assert from "node:assert/strict"
import { execFileSync } from "node:child_process"
import { copyFile, mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"
import test from "node:test"

test("the release build passes the macOS Ghostty archive without overriding project linker flags", async (t) => {
  const root = await mkdtemp(join(tmpdir(), "codevisor-release-linking-"))
  t.after(() => rm(root, { recursive: true, force: true }))
  const script = join(root, "scripts/release/build-macos-xcode.sh")
  await mkdir(join(script, ".."), { recursive: true })
  await copyFile(new URL("./build-macos-xcode.sh", import.meta.url), script)
  // Mirror a real GhosttyKit.xcframework: the iOS slices sort before the macOS
  // slice and their archives also contain arm64, so only Info.plist tells them apart.
  const framework = join(root, "apps/macos/Frameworks/GhosttyKit.xcframework")
  const slices = [
    { id: "ios-arm64", archive: "libghostty-internal.a", platform: "ios" },
    {
      id: "ios-arm64-simulator",
      archive: "libghostty-internal.a",
      platform: "ios",
      variant: "simulator"
    },
    { id: "macos custom slice", archive: "custom archive.a", platform: "macos" }
  ]
  for (const { id, archive } of slices) {
    await mkdir(join(framework, id, "Headers"), { recursive: true })
    await writeFile(join(framework, id, archive), "fixture")
    await writeFile(join(framework, id, "Headers/ghostty.h"), "fixture")
  }
  const entries = slices.map(({ id, archive, platform, variant }) =>
    [
      "<dict>",
      `<key>LibraryIdentifier</key><string>${id}</string>`,
      `<key>LibraryPath</key><string>${archive}</string>`,
      "<key>HeadersPath</key><string>Headers</string>",
      `<key>SupportedPlatform</key><string>${platform}</string>`,
      variant ? `<key>SupportedPlatformVariant</key><string>${variant}</string>` : "",
      "</dict>"
    ].join("")
  )
  await writeFile(
    join(framework, "Info.plist"),
    `<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><dict><key>AvailableLibraries</key><array>${entries.join("")}</array></dict></plist>\n`
  )
  const slice = join(framework, "macos custom slice")
  const library = join(slice, "custom archive.a")
  const resources = join(root, "apps/macos/Codevisor/Resources")
  await mkdir(resources, { recursive: true })
  await writeFile(join(resources, "ghostty-resources.tar.gz"), "fixture")
  const bin = join(root, "bin")
  await mkdir(bin)
  const commands = {
    lipo: 'printf "arm64 x86_64\\n"',
    node: 'printf "%s\\n" "$@" >> "$TEST_NODE_ARGS"',
    xcodebuild:
      'printf "%s\\n" "$@" > "$TEST_XCODE_ARGS"\nmkdir -p "$TEST_APP/Contents/MacOS"\ncp "$TEST_EXECUTABLE" "$TEST_APP/Contents/MacOS/Codevisor"'
  }
  for (const [command, body] of Object.entries(commands)) {
    await writeFile(join(bin, command), `#!/bin/sh\nset -eu\n${body}\n`, { mode: 0o755 })
  }
  const derived = join(root, "DerivedData")
  const captured = join(root, "xcode-args")
  const nodeArgs = join(root, "node-args")
  execFileSync("bash", [script, derived], {
    env: {
      PATH: `${bin}:${process.env.PATH}`,
      TEST_XCODE_ARGS: captured,
      TEST_NODE_ARGS: nodeArgs,
      TEST_APP: join(derived, "Build/Products/Release/Codevisor.app"),
      TEST_EXECUTABLE: process.execPath
    },
    stdio: "pipe"
  })
  const args = (await readFile(captured, "utf8")).trim().split("\n")
  assert.ok(args.includes(`CODEVISOR_GHOSTTY_LIBRARY=${library}`))
  assert.ok(args.includes(`SWIFT_INCLUDE_PATHS=${slice}/Headers`))
  assert.ok(args.includes("ARCHS=arm64"))
  assert.ok(!args.some((arg) => arg.startsWith("OTHER_LDFLAGS=")))
  assert.match(
    await readFile(nodeArgs, "utf8"),
    /macos-browser-artifact\.mjs\nlinkage\n[^\n]+\narm64\n$/
  )
})
