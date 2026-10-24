import { execFile, spawn } from "node:child_process"
import { copyFile, mkdir, mkdtemp, open, readFile, realpath } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { fileURLToPath } from "node:url"
import { promisify } from "node:util"

import { developmentLayout, IOS_DEVELOPMENT_BUNDLE_IDENTIFIER } from "./dev-layout.mjs"
import { describeExit, waitForExit } from "./dev-shared.mjs"
import { devices, parseOptions, selectRuntime } from "./screenshots-ios-lib.mjs"
import { pngDimensions, scenes, selectedAppearances } from "./screenshots-lib.mjs"
import { runXcodebuild } from "./xcodebuild.mjs"

const execute = promisify(execFile)
const settleSeconds = { "04-browser": 8 }
const defaultSettleSeconds = 4
const readyTimeoutSeconds = 90
const pngWidthOffset = 16
const pngHeightOffset = 20
const warmUpScene = "04-browser"

const root = await realpath(fileURLToPath(new URL("..", import.meta.url)))
const options = parseOptions(process.argv.slice(2), root)
if (options.help) {
  console.log(`Usage: bun run screenshots:ios:direct [--device iphone|iphone-18-pro|ipad-pro-11] [--output directory] [--runtime 'iOS 27.0'] [--appearance all|light|dark]

Captures the App Store scenes on a throwaway, headless simulator without the worktree simulator
owner. The device is created for this run and deleted afterwards; the app runs on offline demo
data only. Landscape devices (the iPad) rotate through a UI test, since simctl can't rotate.`)
  process.exit(0)
}

const selectedDevice = devices[options.device]
if (selectedDevice === undefined) throw new Error("Pick one device with --device")
const statusBarTime = new Date(2001, 7, 8, 14, 5).toISOString()
const displayName = "INFOPLIST_KEY_CFBundleDisplayName=Codevisor"
const isLandscape = selectedDevice.orientation === "landscape"
const buildSettings = [displayName]
await run("bun", ["scripts/build-native.mjs", "ios", ...buildSettings])
const runtime = await compatibleRuntime(selectedDevice)
const simulatorId = await simctl(
  "create",
  `Codevisor Screenshots ${selectedDevice.name}`,
  selectedDevice.type,
  runtime.identifier
)
try {
  await prepareDevice(simulatorId)
  if (!isLandscape) await warmUp(simulatorId)
  for (const appearance of selectedAppearances(options)) {
    await simctl("ui", simulatorId, "appearance", appearance)
    const directory = join(options.output, options.device, appearance)
    await mkdir(directory, { recursive: true })
    for (const scene of selectedDevice.scenes ?? scenes) {
      const file = join(directory, `${scene}-${options.device}-${appearance}.png`)
      if (isLandscape) await captureLandscape(simulatorId, appearance, file)
      else await capture(simulatorId, scene, appearance, file)
      console.log(file)
    }
  }
} finally {
  await simctl("shutdown", simulatorId).catch(() => {})
  await simctl("delete", simulatorId)
}

async function prepareDevice(udid) {
  await boot(udid)
  await simctl("spawn", udid, "defaults", "write", "-g", "AppleICUForce24HourTime", "-bool", "YES")
  await simctl("shutdown", udid)
  await boot(udid)
  await simctl("install", udid, appBundle())
  await simctl(
    "spawn",
    udid,
    "defaults",
    "write",
    "com.apple.keyboard.preferences",
    "DidShowContinuousPathIntroduction",
    "-bool",
    "YES"
  )
  await simctl(
    "status_bar",
    udid,
    "override",
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
  await simctl("status_bar", udid, "override", "--time", statusBarTime)
}

async function boot(udid) {
  await simctl("boot", udid)
  await simctl("bootstatus", udid, "-b")
}

async function warmUp(udid) {
  await execute("xcrun", launchArguments(udid), { env: sceneEnvironment(warmUpScene, "light") })
  await sleep(settleSeconds[warmUpScene])
  await simctl("terminate", udid, IOS_DEVELOPMENT_BUNDLE_IDENTIFIER).catch(() => {})
}

async function capture(udid, scene, appearance, file) {
  const readyFile = join(await mkdtemp(join(tmpdir(), "codevisor-ready-")), "ready")
  const environment = {
    ...sceneEnvironment(scene, appearance),
    SIMCTL_CHILD_CODEVISOR_SCREENSHOT_READY_FILE: readyFile
  }
  await execute("xcrun", launchArguments(udid), { env: environment })
  await waitForFile(readyFile)
  await sleep(settleSeconds[scene] ?? defaultSettleSeconds)
  await simctl("io", udid, "screenshot", file)
  await simctl("terminate", udid, IOS_DEVELOPMENT_BUNDLE_IDENTIFIER).catch(() => {})
  pngDimensions(await readFile(file), selectedDevice)
}

async function waitForFile(path) {
  for (let elapsed = 0; elapsed < readyTimeoutSeconds * 10; elapsed++) {
    if (
      await readFile(path).then(
        () => true,
        () => false
      )
    )
      return
    await sleep(0.1)
  }
  throw new Error(`The app did not report ready within ${readyTimeoutSeconds} seconds`)
}

async function captureLandscape(udid, appearance, file) {
  const scratch = await mkdtemp(join(tmpdir(), "codevisor-landscape-"))
  const result = join(scratch, "capture.xcresult")
  await runLandscapeTest(udid, appearance, result, join(scratch, "test.log"))
  const attachments = join(scratch, "attachments")
  await execute("xcrun", [
    "xcresulttool",
    "export",
    "attachments",
    "--path",
    result,
    "--output-path",
    attachments
  ])
  const manifest = JSON.parse(await readFile(join(attachments, "manifest.json"), "utf8"))
  const screenshot = manifest
    .flatMap((test) => test.attachments)
    .find((attachment) =>
      attachment.suggestedHumanReadableName.startsWith("landscape-conversation")
    )
  if (screenshot === undefined) throw new Error(`No landscape screenshot in ${result}`)
  await copyFile(join(attachments, screenshot.exportedFileName), file)
  await turnUpright(file)
  console.log(await eraseResizeGrabber(file))
  const landscape = {
    ...selectedDevice,
    width: selectedDevice.height,
    height: selectedDevice.width
  }
  pngDimensions(await readFile(file), landscape)
}

async function eraseResizeGrabber(file) {
  const script = join(root, "scripts/screenshots-ipad-cleanup.swift")
  return (await execute("xcrun", ["swift", script, file])).stdout.trim()
}

async function turnUpright(file) {
  const header = await readFile(file)
  const isPortrait = header.readUInt32BE(pngHeightOffset) > header.readUInt32BE(pngWidthOffset)
  if (isPortrait) await execute("sips", ["--rotate", "270", file])
}

async function runLandscapeTest(udid, appearance, result, logFile) {
  const log = await open(logFile, "w")
  try {
    await runXcodebuild(root, "ios", landscapeTestArguments(udid, result), {
      layout: developmentLayout(root),
      environment: {
        ...process.env,
        TEST_RUNNER_CODEVISOR_CAPTURE_LANDSCAPE: "1",
        TEST_RUNNER_CODEVISOR_SCREENSHOT_APPEARANCE: appearance
      },
      stdio: ["ignore", log.fd, log.fd]
    })
  } catch (error) {
    throw new Error(`${error.message}. See ${logFile}`, { cause: error })
  } finally {
    await log.close()
  }
}

function landscapeTestArguments(udid, result) {
  return [
    "-project",
    "apps/ios/Codevisor.xcodeproj",
    "-scheme",
    "Codevisor",
    "-configuration",
    "Debug",
    `CODEVISOR_IOS_BUNDLE_IDENTIFIER=${IOS_DEVELOPMENT_BUNDLE_IDENTIFIER}`,
    ...buildSettings,
    `ARCHS=${process.arch === "arm64" ? "arm64" : "x86_64"}`,
    "-destination",
    `platform=iOS Simulator,id=${udid}`,
    "-only-testing:NavigationTests/AppStoreScreenshotTests/testCaptureLandscapeConversation",
    "-resultBundlePath",
    result,
    "test"
  ]
}

function launchArguments(udid) {
  return [
    "simctl",
    "launch",
    "--terminate-running-process",
    udid,
    IOS_DEVELOPMENT_BUNDLE_IDENTIFIER,
    "-AppleLanguages",
    "(en)",
    "-AppleLocale",
    "en_US"
  ]
}

function sceneEnvironment(scene, appearance) {
  const name = scene.replace(/^\d+-/, "")
  return {
    ...process.env,
    SIMCTL_CHILD_CODEVISOR_APP_STORE_SCREENSHOTS: "1",
    SIMCTL_CHILD_CODEVISOR_SCREENSHOT_SCENE: name,
    SIMCTL_CHILD_CODEVISOR_SCREENSHOT_APPEARANCE: appearance,
    SIMCTL_CHILD_CODEVISOR_SCREENSHOT_OPENS_NEW_CHAT: name === "new-chat" ? "1" : "0"
  }
}

async function compatibleRuntime(device) {
  const { runtimes } = JSON.parse(await simctl("list", "runtimes", "--json"))
  return selectRuntime(runtimes, [device], options.runtime)
}

function appBundle() {
  const products = join(developmentLayout(root).build.ios.derivedData, "Build/Products")
  return join(products, "Debug-iphonesimulator/Codevisor.app")
}

async function simctl(...args) {
  return (
    await execute("xcrun", ["simctl", ...args], { maxBuffer: 16 * 1024 * 1024 })
  ).stdout.trim()
}

function sleep(seconds) {
  return new Promise((resolve) => setTimeout(resolve, seconds * 1000))
}

async function run(command, args) {
  const child = spawn(command, args, { cwd: root, stdio: "inherit" })
  const exit = await waitForExit(child)
  if (exit.code !== 0) throw new Error(`${command} exited with ${describeExit(exit)}`)
}
