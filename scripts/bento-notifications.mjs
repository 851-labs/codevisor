import { execFile, spawn } from "node:child_process"
import { copyFile, mkdir, mkdtemp, readFile, realpath, rm, writeFile } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join, resolve } from "node:path"
import process from "node:process"
import { fileURLToPath } from "node:url"
import { parseArgs, promisify } from "node:util"

import { developmentLayout } from "./dev-layout.mjs"
import { delay, describeExit, waitForExit } from "./dev-shared.mjs"
import { restoresHiddenApps, run } from "./screenshots-lib.mjs"

const execute = promisify(execFile)
const screenshotBundleIdentifier = "com.851labs.Codevisor.Screenshots"
const readyTimeoutSeconds = 120
const bannerSettleSeconds = 1.5

const usage = `Usage: bun run bento:notifications [--output directory] [--skip-build]

Posts the landing page's two chat notifications from the Debug macOS app through its real
notification code, then captures the banners over the desktop wallpaper as
notifications-<light|dark>@2x.png in the current system appearance.

The notifications come from a copy of the Debug app with its own bundle identifier
(${screenshotBundleIdentifier}) and the production icon, so the banners show the shipping icon
and the development app's notification settings stay untouched. Its first run asks for
notification permission. Hide other apps before capturing so the banners sit on the bare desktop.`

const root = await realpath(fileURLToPath(new URL("..", import.meta.url)))
const { values: options } = parseArgs({
  options: {
    output: { type: "string", default: "tmp/bento-shots" },
    "skip-build": { type: "boolean", default: false },
    help: { type: "boolean", default: false }
  }
})
if (options.help) {
  console.log(usage)
  process.exit(0)
}

if (!options["skip-build"]) await run("bun", ["scripts/build-native.mjs", "macos"], { cwd: root })
const output = resolve(root, options.output)
await mkdir(output, { recursive: true })
const scratch = await mkdtemp(join(tmpdir(), "codevisor-bento-notifications-"))
const hiddenApps = restoresHiddenApps(scratch)
try {
  const app = await prepareScreenshotApp(scratch)
  const capture = join(scratch, "capture")
  await execute("xcrun", [
    "swiftc",
    "-O",
    join(root, "scripts/bento-notifications-capture.swift"),
    "-o",
    capture
  ])
  const child = spawn(join(app, "Contents/MacOS/Codevisor"), ["-AppleLocale", "en_US@hours=h23"], {
    cwd: root,
    env: {
      ...process.env,
      ...hiddenApps.environment,
      CODEVISOR_BENTO_NOTIFICATIONS: scratch,
      CODEVISOR_DEMO_REPO: root
    },
    stdio: "inherit"
  })
  try {
    const status = await waitForReady(join(scratch, "ready"))
    if (!status.startsWith("posted")) throw new Error(`Notifications were not posted: ${status}`)
    console.log(`App status: ${status}`)
    await delay(bannerSettleSeconds * 1000)
    console.log((await execute(capture, [output])).stdout.trim())
  } finally {
    await writeFile(join(scratch, "done"), "")
    const exit = await waitForExit(child)
    if (exit.code !== 0) console.error(`The app exited with ${describeExit(exit)}`)
  }
} finally {
  hiddenApps.restore()
  await rm(scratch, { recursive: true, force: true })
}

async function waitForReady(file) {
  for (let elapsed = 0; elapsed < readyTimeoutSeconds * 10; elapsed++) {
    const status = await readFile(file, "utf8").catch(() => "")
    if (status !== "") return status
    await delay(100)
  }
  throw new Error(`The app did not post within ${readyTimeoutSeconds} seconds`)
}

async function prepareScreenshotApp(workDirectory) {
  const products = join(developmentLayout(root).build.macos.derivedData, "Build/Products/Debug")
  const app = join(root, "tmp/build/macos/Screenshots/Codevisor.app")
  await rm(app, { recursive: true, force: true })
  await mkdir(join(app, ".."), { recursive: true })
  await execute("ditto", [join(products, "Codevisor.app"), app])
  await execute("xcrun", [
    "actool",
    join(root, "apps/macos/Codevisor/Resources/AppIcon.icon"),
    "--compile",
    workDirectory,
    "--platform",
    "macosx",
    "--minimum-deployment-target",
    "26.0",
    "--app-icon",
    "AppIcon",
    "--output-partial-info-plist",
    join(workDirectory, "icon.plist")
  ])
  await copyFile(join(workDirectory, "AppIcon.icns"), join(app, "Contents/Resources/AppIcon.icns"))
  const plist = join(app, "Contents/Info.plist")
  for (const command of [
    `Set :CFBundleIdentifier ${screenshotBundleIdentifier}`,
    "Set :CFBundleIconFile AppIcon",
    "Delete :CFBundleIconName"
  ]) {
    await execute("/usr/libexec/PlistBuddy", ["-c", command, plist])
  }
  await execute("codesign", ["--force", "--deep", "--sign", "-", app])
  return app
}
