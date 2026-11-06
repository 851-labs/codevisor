import { execFile } from "node:child_process"
import { copyFile, mkdir, mkdtemp, open, readFile, realpath } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { fileURLToPath } from "node:url"
import { promisify } from "node:util"

import { developmentLayout, IOS_DEVELOPMENT_BUNDLE_IDENTIFIER } from "./dev-layout.mjs"
import { delay } from "./dev-shared.mjs"
import {
  devices,
  iosScenes,
  isDarkBitmap,
  parseOptions,
  prepareThrowawaySimulator,
  requireSimulatorSdk,
  selectRuntime,
  simctl
} from "./screenshots-ios-lib.mjs"
import { pngDimensions, run, selectedAppearances } from "./screenshots-lib.mjs"
import { runXcodebuild } from "./xcodebuild.mjs"

const execute = promisify(execFile)
const settleSeconds = 4
const readyTimeoutSeconds = 90
const unfoldTimeoutSeconds = 30
const openHingeDegrees = 180
const settingsSections = { harnesses: "agents", updates: "updates" }
const landscapeMarkers = {
  conversation: "Skin tones are in the picker.",
  harnesses: "Accounts",
  updates: "Update All"
}
const pngWidthOffset = 16
const pngHeightOffset = 20

const root = await realpath(fileURLToPath(new URL("..", import.meta.url)))
const options = parseOptions(process.argv.slice(2), root)
if (options.help) {
  console.log(`Usage: bun run screenshots:ios:direct [--device iphone|iphone-18-pro|iphone-duo|iphone-duo-unfolded|ipad-pro-11|ipad-pro-13] [--output directory] [--runtime 'iOS 27.0'] [--appearance all|light|dark]

Captures the App Store scenes on a throwaway, headless simulator without the worktree simulator
owner. The device is created for this run and deleted afterwards; the app runs on offline demo
data only. Landscape devices (the iPad) rotate through a UI test, since simctl can't rotate.
iphone-duo-unfolded opens the simulator's hinge the way the Codevisor simulator pane does, then
captures the inner display.`)
  process.exit(0)
}

const selectedDevice = devices[options.device]
if (selectedDevice === undefined) throw new Error("Pick one device with --device")
await requireSimulatorSdk(selectedDevice)
const displayName = "INFOPLIST_KEY_CFBundleDisplayName=Codevisor"
const isLandscape = selectedDevice.orientation === "landscape"
const buildSettings = [displayName]
await run("bun", ["scripts/build-native.mjs", "ios", ...buildSettings], {
  cwd: root
})
const runtime = await compatibleRuntime(selectedDevice)
const simulatorId = await simctl(
  "create",
  `Codevisor Screenshots ${selectedDevice.name}`,
  selectedDevice.type,
  runtime.identifier
)
try {
  await prepareDevice(simulatorId)
  if (selectedDevice.unfolded) await unfold(simulatorId)
  for (const appearance of selectedAppearances(options)) {
    await simctl("ui", simulatorId, "appearance", appearance)
    const directory = join(options.output, options.device, appearance)
    await mkdir(directory, { recursive: true })
    for (const scene of selectedDevice.scenes ?? iosScenes) {
      const file = join(directory, `${scene}-${options.device}-${appearance}.png`)
      if (isLandscape) await captureLandscape(simulatorId, scene, appearance, file)
      else await capture(simulatorId, scene, appearance, file)
      console.log(file)
    }
  }
} finally {
  await simctl("shutdown", simulatorId).catch(() => {})
  await simctl("delete", simulatorId)
}

async function prepareDevice(udid) {
  await prepareThrowawaySimulator(udid)
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
}

async function unfold(udid) {
  const hinge = join(root, "scripts/simulator-hinge.swift")
  await execute("xcrun", ["swift", hinge, udid, String(openHingeDegrees)])
  const scratch = await mkdtemp(join(tmpdir(), "codevisor-unfold-"))
  const screen = join(scratch, "inner.png")
  const thumbnail = join(scratch, "inner.bmp")
  const deadline = Date.now() + unfoldTimeoutSeconds * 1000
  while (Date.now() < deadline) {
    await simctl("io", udid, "screenshot", "--display", selectedDevice.display, screen)
    await execute("sips", ["-Z", "64", "-s", "format", "bmp", screen, "--out", thumbnail])
    if (!isDarkBitmap(await readFile(thumbnail))) return
    await delay(1000)
  }
  throw new Error(
    `The ${selectedDevice.name} inner display stayed dark ${unfoldTimeoutSeconds} seconds after unfolding`
  )
}

async function capture(udid, scene, appearance, file) {
  const readyFile = join(await mkdtemp(join(tmpdir(), "codevisor-ready-")), "ready")
  const environment = {
    ...sceneEnvironment(scene, appearance),
    SIMCTL_CHILD_CODEVISOR_SCREENSHOT_READY_FILE: readyFile
  }
  await execute("xcrun", launchArguments(udid), { env: environment })
  await waitForFile(readyFile)
  await delay(settleSeconds * 1000)
  const display = selectedDevice.display === undefined ? [] : ["--display", selectedDevice.display]
  await simctl("io", udid, "screenshot", ...display, file)
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
    await delay(100)
  }
  throw new Error(`The app did not report ready within ${readyTimeoutSeconds} seconds`)
}

async function captureLandscape(udid, scene, appearance, file) {
  const scratch = await mkdtemp(join(tmpdir(), "codevisor-landscape-"))
  const result = join(scratch, "capture.xcresult")
  await runLandscapeTest(udid, scene, appearance, result, join(scratch, "test.log"))
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
    .find((attachment) => attachment.suggestedHumanReadableName.startsWith("landscape"))
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

async function runLandscapeTest(udid, scene, appearance, result, logFile) {
  const name = sceneName(scene)
  const log = await open(logFile, "w")
  try {
    await runXcodebuild(root, "ios", landscapeTestArguments(udid, result), {
      layout: developmentLayout(root),
      environment: {
        ...process.env,
        TEST_RUNNER_CODEVISOR_CAPTURE_LANDSCAPE: "1",
        TEST_RUNNER_CODEVISOR_SCREENSHOT_APPEARANCE: appearance,
        TEST_RUNNER_CODEVISOR_SCREENSHOT_SCENE: name,
        TEST_RUNNER_CODEVISOR_SCREENSHOT_MARKER: landscapeMarkers[name],
        ...(name in settingsSections
          ? { TEST_RUNNER_CODEVISOR_SCREENSHOT_SETTINGS_SECTION: settingsSections[name] }
          : {})
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
    "-only-testing:NavigationTests/AppStoreScreenshotTests/testCaptureLandscape",
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

function sceneName(scene) {
  return scene.replace(/^\d+-/, "")
}

function sceneEnvironment(scene, appearance) {
  const name = sceneName(scene)
  return {
    ...process.env,
    SIMCTL_CHILD_CODEVISOR_APP_STORE_SCREENSHOTS: "1",
    SIMCTL_CHILD_CODEVISOR_SCREENSHOT_SCENE: name,
    SIMCTL_CHILD_CODEVISOR_SCREENSHOT_APPEARANCE: appearance,
    ...(name in settingsSections
      ? { SIMCTL_CHILD_CODEVISOR_SCREENSHOT_SETTINGS_SECTION: settingsSections[name] }
      : {})
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
