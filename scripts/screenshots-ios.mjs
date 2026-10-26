import { realpath } from "node:fs/promises"
import { join } from "node:path"
import { fileURLToPath } from "node:url"

import { bootstrapDevelopment } from "./dev-bootstrap.mjs"
import { iosDevelopmentBundleIdentifier } from "./dev-layout.mjs"
import { requireIOSSimulator } from "./ios-simulator-state.mjs"
import { createCapture } from "./screenshots-capture.mjs"
import { devices, parseOptions, selectRuntime } from "./screenshots-ios-lib.mjs"
import { selectedAppearances } from "./screenshots-lib.mjs"

const root = await realpath(fileURLToPath(new URL("..", import.meta.url)))
const options = parseOptions(process.argv.slice(2), root)
if (options.help) {
  console.log(
    "Usage: bun run screenshots:ios [--device iphone|iphone-18-pro|ipad-pro-11] [--output directory] [--runtime 'iOS 27.0'] [--appearance all|light|dark]"
  )
  process.exit(0)
}
if (process.platform !== "darwin")
  throw new Error("iOS screenshots require macOS and Xcode with an iOS Simulator runtime.")

const simulator = await requireIOSSimulator(root)
const { output, command, build, exportImages, finish } = await createCapture(root, "ios", options)
const simctl = (...args) => command("xcrun", ["simctl", ...args])
const device = devices[options.device]
if (device.orientation === "landscape")
  throw new Error(
    `The UI-test capture only runs in portrait. Capture ${device.name} with: bun run screenshots:ios:direct --device ${options.device}`
  )
const { runtimes } = JSON.parse(await simctl("list", "runtimes", "--json"))
const runtime = selectRuntime(runtimes, [device], options.runtime ?? simulator.runtimeIdentifier)
if (runtime.identifier !== simulator.runtimeIdentifier || device.type !== simulator.deviceType)
  throw new Error(
    `Screenshot capture requires the worktree simulator to use ${device.name} and the requested runtime. Restart its owner with: bun run ios-simulator --device="${device.name}"`
  )
await bootstrapDevelopment(root, { ghosttyKit: true })
const bundle = `${iosDevelopmentBundleIdentifier(root)}.screenshots`
const baseArguments = [
  "-project",
  "apps/ios/Codevisor.xcodeproj",
  "-scheme",
  "Codevisor",
  "-configuration",
  "Debug",
  `CODEVISOR_IOS_BUNDLE_IDENTIFIER=${bundle}`,
  "INFOPLIST_KEY_CFBundleDisplayName=Codevisor",
  `ARCHS=${process.arch === "arm64" ? "arm64" : "x86_64"}`,
  "-parallel-testing-enabled",
  "NO",
  "-collect-test-diagnostics",
  "never",
  "-only-testing:NavigationTests/AppStoreScreenshotTests",
  "-quiet"
]
const originalAppearance = await simctl("ui", simulator.udid, "appearance")
const cleanup = async () => {
  await simctl("status_bar", simulator.udid, "clear")
  await simctl("ui", simulator.udid, "appearance", originalAppearance)
}
for (const signal of ["SIGINT", "SIGTERM"]) {
  process.once(signal, () => {
    void cleanup().finally(() => process.exit(signal === "SIGINT" ? 130 : 143))
  })
}

await build(
  [...baseArguments, "-destination", "generic/platform=iOS Simulator", "build-for-testing"],
  "build.log"
)
try {
  console.log(`Capturing ${device.name} (${runtime.name})…`)
  await simctl(
    "spawn",
    simulator.udid,
    "defaults",
    "write",
    "com.apple.keyboard.preferences",
    "DidShowContinuousPathIntroduction",
    "-bool",
    "YES"
  )
  await simctl(
    "status_bar",
    simulator.udid,
    "override",
    "--time",
    new Date(2026, 8, 14, 9, 41).toISOString(),
    "--dataNetwork",
    "wifi",
    "--wifiMode",
    "active",
    "--wifiBars",
    "3",
    "--batteryState",
    "discharging",
    "--batteryLevel",
    "100"
  )
  for (const appearance of selectedAppearances(options)) {
    console.log(`Capturing ${options.device} · ${appearance}…`)
    await simctl("ui", simulator.udid, "appearance", appearance)
    const result = join(output, `${options.device}-${appearance}.xcresult`)
    await build(
      [
        ...baseArguments,
        "-destination",
        `platform=iOS Simulator,id=${simulator.udid}`,
        "-resultBundlePath",
        result,
        "test-without-building"
      ],
      `${options.device}-${appearance}.log`,
      appearance
    )
    await exportImages(result, options.device, device, appearance)
  }
} finally {
  await cleanup()
}
await finish({ runtime: runtime.name, bundleIdentifier: bundle })
