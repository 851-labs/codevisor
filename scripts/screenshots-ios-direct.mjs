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
  parseOptions,
  prepareThrowawaySimulator,
  requireSimulatorSdk,
  selectRuntime,
  simctl,
  startMascotServer
} from "./screenshots-ios-lib.mjs"
import { pngDimensions, run, selectedAppearances } from "./screenshots-lib.mjs"
import { runXcodebuild } from "./xcodebuild.mjs"

const execute = promisify(execFile)
const settleSeconds = { browser: 8, bots: 6, "bot-conversation": 6, "mascot-editor": 6 }
const defaultSettleSeconds = 4
const readyTimeoutSeconds = 90
const pngWidthOffset = 16
const pngHeightOffset = 20
const warmUpScene = "07-browser"
const landscapeMarkers = {
  "bot-conversation": "TestFlight build 318",
  conversation: "Skin tones are in the picker.",
  "mascot-editor": "Headwear",
  browser: "Copy emoji"
}

const root = await realpath(fileURLToPath(new URL("..", import.meta.url)))
const options = parseOptions(process.argv.slice(2), root)
if (options.help) {
  console.log(`Usage: bun run screenshots:ios:direct [--device iphone|iphone-18-pro|iphone-duo|ipad-pro-11|ipad-pro-13] [--output directory] [--runtime 'iOS 27.0'] [--appearance all|light|dark]

Captures the App Store scenes on a throwaway, headless simulator without the worktree simulator
owner. The device is created for this run and deleted afterwards; the app runs on offline demo
data only. Landscape devices (the iPad) rotate through a UI test, since simctl can't rotate.`)
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
const mascotServer = await startMascotServer(root)
try {
  await captureAll()
} finally {
  await mascotServer.stop()
}

async function captureAll() {
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

async function warmUp(udid) {
  await execute("xcrun", launchArguments(udid), {
    env: sceneEnvironment(warmUpScene, "light")
  })
  await delay(settleSeconds[sceneName(warmUpScene)] * 1000)
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
  await delay((settleSeconds[sceneName(scene)] ?? defaultSettleSeconds) * 1000)
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

async function runLandscapeTest(udid, scene, appearance, result, logFile) {
  const log = await open(logFile, "w")
  try {
    await runXcodebuild(root, "ios", landscapeTestArguments(udid, result), {
      layout: developmentLayout(root),
      environment: {
        ...process.env,
        TEST_RUNNER_CODEVISOR_CAPTURE_LANDSCAPE: "1",
        TEST_RUNNER_CODEVISOR_SCREENSHOT_APPEARANCE: appearance,
        TEST_RUNNER_CODEVISOR_SCREENSHOT_SCENE: sceneName(scene),
        TEST_RUNNER_CODEVISOR_SCREENSHOT_MARKER: landscapeMarkers[sceneName(scene)],
        TEST_RUNNER_CODEVISOR_DEMO_MASCOT_URL: mascotServer.url
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

function sceneName(scene) {
  return scene.replace(/^\d+-/, "")
}

function sceneEnvironment(scene, appearance) {
  const name = sceneName(scene)
  return {
    ...process.env,
    SIMCTL_CHILD_CODEVISOR_DEMO_MASCOT_URL: mascotServer.url,
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
