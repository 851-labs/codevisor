import { execFile, spawn } from "node:child_process"
import { mkdir, mkdtemp, readFile, realpath, rm } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { fileURLToPath } from "node:url"
import { promisify } from "node:util"

import { developmentLayout } from "./dev-layout.mjs"
import { delay, waitForExit } from "./dev-shared.mjs"
import {
  parseCaptureOptions,
  pngDimensions,
  restoresHiddenApps,
  run,
  scenes,
  selectedAppearances
} from "./screenshots-lib.mjs"

const execute = promisify(execFile)
const fullscreenFlag = "--fullscreen"
const worktreePickerFlag = "--worktree-picker"
const inspectorFlag = "--inspector"
const skipBuildFlag = "--skip-build"
const desktopFlag = "--desktop"
const isFullscreen = process.argv.includes(fullscreenFlag)
const showsWorktreePicker = process.argv.includes(worktreePickerFlag)
const showsInspector = process.argv.includes(inspectorFlag)
const showsDesktop = process.argv.includes(desktopFlag)
const window = capturedWindow()
const variant = [
  "macos",
  ...(isFullscreen ? ["fullscreen"] : []),
  ...(showsWorktreePicker ? ["worktree-picker"] : []),
  ...(showsInspector ? ["inspector"] : []),
  ...(showsDesktop ? ["desktop"] : [])
].join("-")
const capturedScenes = capturedScenesForVariant()
const runPickerArea = { x: 810, y: 872, width: 690, height: 364 }
const inspectorArea = { x: 2040, y: 0, width: 520, height: 1818 }
const settleSeconds = { "04-browser": 8 }
const defaultSettleSeconds = 3
const windowTimeoutSeconds = 60

const root = await realpath(fileURLToPath(new URL("..", import.meta.url)))
const options = parseCaptureOptions(
  process.argv
    .slice(2)
    .filter(
      (argument) =>
        ![fullscreenFlag, worktreePickerFlag, inspectorFlag, skipBuildFlag, desktopFlag].includes(
          argument
        )
    ),
  root,
  "macos"
)
if (options.help) {
  console.log(`Usage: bun run screenshots:macos:direct [--output directory] [--appearance all|light|dark] [--fullscreen] [--worktree-picker] [--inspector] [--skip-build]

--fullscreen sizes the window to fill a 14-inch MacBook Pro below the menu bar (1512x945 pt).
--worktree-picker captures New Chat with the "Run in" menu open on New worktree.
--desktop captures the whole main display: the conversation window inset over the wallpaper (add --inspector to open it), with
the real menu bar. Other apps are hidden during the capture and shown again afterwards; the system
appearance must match --appearance.
--inspector captures the conversation with the workspace inspector open on Info, plus a crop of
the inspector's Details, Machine, and Usage sections.

Captures the App Store scenes from the Debug macOS app without UI testing, so it needs no
automation-mode approval. The app runs on offline demo data only; it never starts the
client runtime, a server, or touches another Codevisor's data.`)
  process.exit(0)
}

if (!process.argv.includes(skipBuildFlag))
  await run("bun", ["scripts/build-native.mjs", "macos"], { cwd: root })
for (const appearance of selectedAppearances(options)) {
  if (showsDesktop && appearance !== (await systemAppearance())) {
    throw new Error(`Switch the system appearance to ${appearance} before capturing the desktop`)
  }
  const directory = join(options.output, variant, appearance)
  await mkdir(directory, { recursive: true })
  for (const scene of capturedScenes) {
    const file = join(directory, `${scene}-${variant}-${appearance}.png`)
    await capture(scene, appearance, file)
    console.log(file)
    if (showsWorktreePicker) {
      console.log(
        await crop(file, join(directory, `worktree-picker-${appearance}@2x.png`), runPickerArea)
      )
    }
    if (showsInspector && !showsDesktop) {
      console.log(
        await crop(file, join(directory, `inspector-window-${appearance}@2x.png`), inspectorArea)
      )
    }
  }
}

async function capture(scene, appearance, file) {
  const scratch = await mkdtemp(join(tmpdir(), "codevisor-screenshot-"))
  const windowFile = join(scratch, "window")
  const hiddenApps = showsDesktop ? restoresHiddenApps(scratch) : undefined
  const app = spawn(appExecutable(), launchArguments(), {
    env: {
      ...sceneEnvironment(scene, appearance, windowFile),
      ...hiddenApps?.environment
    },
    stdio: "ignore"
  })
  try {
    const windowId = await waitForWindow(windowFile)
    await delay((settleSeconds[scene] ?? defaultSettleSeconds) * 1000)
    const target = showsDesktop ? ["-D", "1"] : ["-o", "-l", windowId]
    await execute("/usr/sbin/screencapture", ["-x", ...target, file])
    pngDimensions(await readFile(file), window)
  } finally {
    app.kill("SIGTERM")
    await waitForExit(app)
    hiddenApps?.restore()
    await rm(scratch, { recursive: true, force: true })
  }
}

async function systemAppearance() {
  const style = await execute("defaults", ["read", "-g", "AppleInterfaceStyle"]).then(
    ({ stdout }) => stdout.trim(),
    () => ""
  )
  return style === "Dark" ? "dark" : "light"
}

function capturedWindow() {
  if (showsDesktop) {
    return {
      name: "main display of a 14-inch MacBook Pro",
      width: 1512,
      height: 982,
      scales: [2]
    }
  }
  if (isFullscreen) {
    return {
      name: "Codevisor window filling a 14-inch MacBook Pro",
      width: 1512,
      height: 945,
      scales: [2]
    }
  }
  if (showsInspector) {
    return {
      name: "Codevisor window tall enough for the inspector's Usage",
      width: 1280,
      height: 920,
      scales: [2]
    }
  }
  return { name: "Codevisor window", width: 1280, height: 820, scales: [2] }
}

function capturedScenesForVariant() {
  if (showsWorktreePicker) return ["03-new-chat"]
  if (showsInspector || showsDesktop) return ["02-conversation"]
  return scenes
}

async function crop(file, cropped, area) {
  const { x, y, width, height } = area
  await execute("sips", [
    "--cropToHeightWidth",
    String(height),
    String(width),
    "--cropOffset",
    String(y),
    String(x),
    file,
    "--out",
    cropped
  ])
  return cropped
}

function appExecutable() {
  const products = join(developmentLayout(root).build.macos.derivedData, "Build/Products/Debug")
  return join(products, "Codevisor.app/Contents/MacOS/Codevisor")
}

function launchArguments() {
  return [
    "-AppleLanguages",
    "(en)",
    "-AppleLocale",
    "en_US@hours=h23",
    "-ApplePersistenceIgnoreState",
    "YES",
    "--use-mock-keychain"
  ]
}

function sceneEnvironment(scene, appearance, windowFile) {
  return {
    ...process.env,
    CODEVISOR_APP_STORE_SCREENSHOTS: "1",
    CODEVISOR_SCREENSHOT_SCENE: scene.replace(/^\d+-/, ""),
    CODEVISOR_SCREENSHOT_APPEARANCE: appearance,
    CODEVISOR_SCREENSHOT_WINDOW_FILE: windowFile,
    ...(showsDesktop
      ? {
          CODEVISOR_SCREENSHOT_DESKTOP: "1",
          CODEVISOR_SCREENSHOT_INSPECTOR_WIDTH: "320"
        }
      : {
          CODEVISOR_SCREENSHOT_WINDOW_SIZE: `${window.width}x${window.height}`
        }),
    CODEVISOR_SCREENSHOT_OPENS_RUN_LOCATION_MENU: showsWorktreePicker ? "1" : "0",
    CODEVISOR_SCREENSHOT_SHOWS_INSPECTOR: showsInspector ? "1" : "0"
  }
}

async function waitForWindow(windowFile) {
  for (let elapsed = 0; elapsed < windowTimeoutSeconds * 10; elapsed++) {
    const windowId = await readFile(windowFile, "utf8").catch(() => "")
    if (windowId !== "") return windowId.trim()
    await delay(100)
  }
  throw new Error(`The screenshot window did not appear within ${windowTimeoutSeconds} seconds`)
}
