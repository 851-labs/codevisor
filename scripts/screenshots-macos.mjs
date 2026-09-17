import { realpath } from "node:fs/promises"
import { join } from "node:path"
import { fileURLToPath } from "node:url"

import { bootstrapDevelopment } from "./dev-bootstrap.mjs"
import { iosDevelopmentBundleIdentifier } from "./dev-layout.mjs"
import { createCapture } from "./screenshots-capture.mjs"
import { parseCaptureOptions, selectedAppearances } from "./screenshots-lib.mjs"

const root = await realpath(fileURLToPath(new URL("..", import.meta.url)))
const options = parseCaptureOptions(process.argv.slice(2), root, "macos")
if (options.help) {
  console.log("Usage: bun run screenshots:macos [--output directory] [--appearance all|light|dark]")
  process.exit(0)
}
if (process.platform !== "darwin") throw new Error("macOS screenshots require macOS and Xcode.")
await bootstrapDevelopment(root, { ghostty: true })
const bundle = `${iosDevelopmentBundleIdentifier(root)}.macos-screenshots`
const { output, command, build, exportImages, finish } = await createCapture(root, "macos", {
  ...options,
  bundleIdentifier: bundle
})
const baseArguments = [
  "-project",
  "apps/macos/Codevisor.xcodeproj",
  "-scheme",
  "Screenshots",
  "-configuration",
  "Debug",
  "CODEVISOR_DEV_PRODUCT_NAME=Codevisor",
  "CODEVISOR_DEV_DISPLAY_NAME=Codevisor",
  `CODEVISOR_DEV_BUNDLE_IDENTIFIER=${bundle}`,
  "CODE_SIGN_IDENTITY=-",
  "CODE_SIGNING_ALLOWED=YES",
  `ARCHS=${process.arch === "arm64" ? "arm64" : "x86_64"}`,
  "-destination",
  "platform=macOS",
  "-parallel-testing-enabled",
  "NO",
  "-collect-test-diagnostics",
  "never",
  "-only-testing:ScreenshotTests/AppStoreScreenshotTests",
  "-quiet"
]
await build([...baseArguments, "build-for-testing"], "build.log")
for (const appearance of selectedAppearances(options)) {
  console.log(`Capturing macOS · ${appearance}…`)
  const result = join(output, `macos-${appearance}.xcresult`)
  await build(
    [...baseArguments, "-resultBundlePath", result, "test-without-building"],
    `macos-${appearance}.log`,
    appearance
  )
  await exportImages(
    result,
    "macos",
    { name: "Codevisor window", width: 1280, height: 820, scales: [1, 2] },
    appearance
  )
}
await finish({ osVersion: await command("sw_vers", ["-productVersion"]), bundleIdentifier: bundle })
