import { execFile } from "node:child_process"
import { promisify } from "node:util"
import { copyFile, mkdir, mkdtemp, open, readFile, realpath, writeFile } from "node:fs/promises"
import { join } from "node:path"
import { fileURLToPath } from "node:url"
import { bootstrapDevelopment } from "./dev-bootstrap.mjs"
import { developmentLayout, iosDevelopmentBundleIdentifier } from "./dev-layout.mjs"
import { runXcodebuild } from "./xcodebuild.mjs"
import {
  devices,
  gallery,
  parseOptions,
  pngDimensions,
  screenshotAttachments,
  selectRuntime
} from "./screenshots-ios-lib.mjs"

const execute = promisify(execFile)
const root = await realpath(fileURLToPath(new URL("..", import.meta.url)))
const options = parseOptions(process.argv.slice(2), root)
if (options.help) {
  console.log(
    "Usage: bun run screenshots:ios [--device all|iphone] [--output directory] [--runtime 'iOS 27.0']"
  )
  process.exit(0)
}
if (process.platform !== "darwin")
  throw new Error("iOS screenshots require macOS and Xcode with an iOS Simulator runtime.")

const command = async (program, args) =>
  (await execute(program, args, { cwd: root, maxBuffer: 16 * 1024 * 1024 })).stdout.trim()
const simctl = (...args) => command("xcrun", ["simctl", ...args])
const selected = Object.entries(devices).filter(
  ([key]) => options.device === "all" || options.device === key
)
const { runtimes } = JSON.parse(await simctl("list", "runtimes", "--json"))
const runtime = selectRuntime(
  runtimes,
  selected.map(([, device]) => device),
  options.runtime
)
await bootstrapDevelopment(root)
await mkdir(options.output, { recursive: true })
const output = await mkdtemp(join(options.output, "capture-"))
const layout = developmentLayout(root)
// Don't replace the build or installed bundle used by this worktree's dev runner.
layout.build.ios = {
  derivedData: join(root, "tmp/build/ios-screenshots/DerivedData"),
  sourcePackages: join(root, "tmp/build/ios-screenshots/SourcePackages")
}
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
const images = []
let ownedSimulator
const cleanup = async () => {
  if (!ownedSimulator) return
  const id = ownedSimulator
  ownedSimulator = undefined
  await simctl("shutdown", id).catch(() => {})
  await simctl("delete", id)
}
for (const signal of ["SIGINT", "SIGTERM"]) {
  process.once(signal, () => {
    void cleanup().finally(() => process.exit(signal === "SIGINT" ? 130 : 143))
  })
}

async function build(arguments_, logfile) {
  const log = await open(join(output, logfile), "w")
  try {
    await runXcodebuild(root, "ios", arguments_, {
      layout,
      environment: { ...process.env, TEST_RUNNER_CODEVISOR_CAPTURE_SCREENSHOTS: "1" },
      stdio: ["ignore", log.fd, log.fd]
    })
  } catch (error) {
    throw new Error(`${error.message}. See ${join(output, logfile)}`, { cause: error })
  } finally {
    await log.close()
  }
}

console.log(`Screenshots: ${output}`)
await build(
  [...baseArguments, "-destination", "generic/platform=iOS Simulator", "build-for-testing"],
  "build.log"
)
try {
  for (const [key, device] of selected) {
    console.log(`Capturing ${device.name} (${runtime.name})…`)
    ownedSimulator = await simctl(
      "create",
      `Codevisor Screenshots ${key} ${process.pid}`,
      device.type,
      runtime.identifier
    )
    await simctl("boot", ownedSimulator)
    await simctl("bootstatus", ownedSimulator, "-b")
    await simctl(
      "spawn",
      ownedSimulator,
      "defaults",
      "write",
      "com.apple.keyboard.preferences",
      "DidShowContinuousPathIntroduction",
      "-bool",
      "YES"
    )
    await simctl("ui", ownedSimulator, "appearance", "light")
    await simctl(
      "status_bar",
      ownedSimulator,
      "override",
      "--time",
      // Keep 9:41 in the host/simulator's local zone.
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
    const result = join(output, `${key}.xcresult`)
    await build(
      [
        ...baseArguments,
        "-destination",
        `platform=iOS Simulator,id=${ownedSimulator}`,
        "-resultBundlePath",
        result,
        "test-without-building"
      ],
      `${key}.log`
    )
    const exports = join(output, `${key}-attachments`)
    await command("xcrun", [
      "xcresulttool",
      "export",
      "attachments",
      "--path",
      result,
      "--output-path",
      exports
    ])
    const attachments = screenshotAttachments(
      JSON.parse(await readFile(join(exports, "manifest.json"), "utf8"))
    )
    await mkdir(join(output, key))
    for (const { scene, filename } of attachments) {
      const source = join(exports, filename)
      const dimensions = pngDimensions(await readFile(source), device)
      const file = `${key}/${scene}-${key}.png`
      await copyFile(source, join(output, file))
      images.push({ device: key, model: device.name, scene, file, ...dimensions })
    }
    await cleanup()
  }
} finally {
  await cleanup()
}
const manifest = {
  sourceCommit: await command("git", ["rev-parse", "HEAD"]),
  workingTreeChanged: (await command("git", ["status", "--porcelain"])).length > 0,
  runtime: runtime.name,
  bundleIdentifier: bundle,
  images
}
await writeFile(join(output, "manifest.json"), `${JSON.stringify(manifest, null, 2)}\n`)
await writeFile(join(output, "index.html"), gallery(images))
console.log(`Saved ${images.length} screenshots. Gallery: ${join(output, "index.html")}`)
