import { spawn } from "node:child_process"
import { access, cp, mkdir, readFile, rm, writeFile } from "node:fs/promises"
import { join } from "node:path"
import process from "node:process"

import { runXcodebuild } from "./xcodebuild.mjs"

export async function buildIOSDevelopmentApp({
  repoRoot,
  layout,
  simulatorName,
  appDisplayName,
  bundleIdentifier,
  urlScheme,
  developmentIconColor,
  environment = process.env,
  didSelectSimulator
}) {
  const simulator = await selectSimulator(repoRoot, simulatorName, environment)
  didSelectSimulator?.(simulator)
  console.log(`  device:    ${simulator.name} (${simulator.runtime}) ${simulator.udid}`)

  // Build and launch against a concrete booted device so this also works from
  // a fresh simulator shutdown.
  await run(repoRoot, environment, "xcrun", ["simctl", "bootstatus", simulator.udid, "-b"])
  await openSimulatorUserInterface(repoRoot, environment)

  const generatedIconDirectory = await createDevelopmentAppIcon(repoRoot, developmentIconColor)
  try {
    await runXcodebuild(
      repoRoot,
      "ios",
      [
        "-project",
        "apps/ios/Codevisor.xcodeproj",
        "-scheme",
        "Codevisor",
        "-configuration",
        "Debug",
        "-destination",
        `platform=iOS Simulator,id=${simulator.udid}`,
        `CODEVISOR_IOS_BUNDLE_IDENTIFIER=${bundleIdentifier}`,
        `CODEVISOR_URL_SCHEME=${urlScheme}`,
        `INFOPLIST_KEY_CFBundleDisplayName=${appDisplayName}`,
        "ASSETCATALOG_COMPILER_APPICON_NAME=AppIconDevGenerated",
        "INFOPLIST_KEY_CFBundleIconName=AppIconDevGenerated",
        "build"
      ],
      { environment, layout }
    )
  } finally {
    await rm(generatedIconDirectory, { recursive: true, force: true })
  }

  return {
    simulator,
    bundleIdentifier,
    appBundle: join(
      layout.build.ios.derivedData,
      "Build",
      "Products",
      "Debug-iphonesimulator",
      "Codevisor.app"
    )
  }
}

export async function launchIOSDevelopmentApp({
  repoRoot,
  target,
  environment = process.env,
  worktreeName,
  instanceName,
  developmentIconColor,
  remoteHost,
  remotePort,
  remoteToken,
  remoteName,
  urlScheme,
  cloudURL
}) {
  const { simulator, bundleIdentifier, appBundle } = target
  await run(repoRoot, environment, "xcrun", ["simctl", "install", simulator.udid, appBundle])
  spawn("xcrun", ["simctl", "terminate", simulator.udid, bundleIdentifier], {
    env: environment,
    stdio: "ignore"
  })
  await delay(500)

  // Match CodevisorAppVariant's development-launch contract so simulator icon
  // relaunches retain the shared remote and cloud coordinates.
  // Only the cloud URL: the simulator app signs in the production way, so
  // cloud machines appear there only after a real sign-in.
  const cloudEnvironment =
    cloudURL === undefined ? {} : { SIMCTL_CHILD_CODEVISOR_DEV_CLOUD_URL: cloudURL }
  await run(
    repoRoot,
    {
      ...environment,
      ...cloudEnvironment,
      SIMCTL_CHILD_CODEVISOR_DEV_WORKTREE: worktreeName,
      SIMCTL_CHILD_CODEVISOR_DEV_INSTANCE_ID: instanceName,
      SIMCTL_CHILD_CODEVISOR_DEV_ICON_COLOR: developmentIconColor.hex,
      SIMCTL_CHILD_CODEVISOR_DEV_REMOTE_HOST: remoteHost,
      SIMCTL_CHILD_CODEVISOR_DEV_REMOTE_PORT: String(remotePort),
      SIMCTL_CHILD_CODEVISOR_DEV_REMOTE_TOKEN: remoteToken,
      SIMCTL_CHILD_CODEVISOR_DEV_REMOTE_NAME: remoteName
    },
    "xcrun",
    ["simctl", "launch", simulator.udid, bundleIdentifier]
  )

  console.log("")
  console.log(`Codevisor iOS is running on ${simulator.name} against the dev remote:`)
  console.log(`  Address: ${remoteHost}:${remotePort}`)
  console.log(`  Token:   ${remoteToken}`)
  console.log(
    `  Or open: ${urlScheme}://add-machine?host=${remoteHost}&port=${remotePort}&token=${remoteToken}&name=${encodeURIComponent(remoteName)}`
  )
  console.log("")
}

export function terminateIOSDevelopmentApp(target) {
  if (target === undefined) return
  spawn("xcrun", ["simctl", "terminate", target.simulator.udid, target.bundleIdentifier], {
    stdio: "ignore"
  }).unref()
}

async function selectSimulator(repoRoot, name, environment) {
  const listing = JSON.parse(
    await capture(repoRoot, environment, "xcrun", [
      "simctl",
      "list",
      "devices",
      "available",
      "--json"
    ])
  )
  const candidates = []
  for (const [runtimeIdentifier, devices] of Object.entries(listing.devices)) {
    const match = runtimeIdentifier.match(/iOS-(\d+)-(\d+)$/)
    if (match === null) continue
    const version = Number(match[1]) * 100 + Number(match[2])
    for (const device of devices) {
      if (device.name !== name) continue
      candidates.push({
        udid: device.udid,
        name: device.name,
        runtime: `iOS ${match[1]}.${match[2]}`,
        version,
        booted: device.state === "Booted"
      })
    }
  }
  if (candidates.length === 0) {
    throw new Error(
      `No available simulator named "${name}" was found. Set CODEVISOR_IOS_SIMULATOR to one of the devices in \`xcrun simctl list devices available\`.`
    )
  }
  // Prefer an already-booted device, then the newest runtime.
  candidates.sort((a, b) => Number(b.booted) - Number(a.booted) || b.version - a.version)
  return candidates[0]
}

// Xcode 27+ replaced Simulator.app with DeviceHub.app.
async function openSimulatorUserInterface(repoRoot, environment) {
  const developerDirectory = (await capture(repoRoot, environment, "xcode-select", ["-p"])).trim()
  const candidates = [
    join(developerDirectory, "Applications", "Simulator.app"),
    join(developerDirectory, "..", "Applications", "DeviceHub.app")
  ]
  for (const candidate of candidates) {
    if (await pathExists(candidate)) {
      await run(repoRoot, environment, "open", [candidate])
      return
    }
  }
  console.warn(
    "No simulator UI app (Simulator.app or DeviceHub.app) was found in the selected Xcode; the app is running headless. Open the simulator UI manually to see it."
  )
}

async function createDevelopmentAppIcon(repoRoot, developmentIconColor) {
  const templateDirectory = join(
    repoRoot,
    "apps",
    "macos",
    "Codevisor",
    "Resources",
    "AppIconDev.icon"
  )
  const generatedDirectory = join(
    repoRoot,
    "apps",
    "ios",
    "Codevisor",
    "Resources",
    "AppIconDevGenerated.icon"
  )
  await rm(generatedDirectory, { recursive: true, force: true })
  await mkdir(join(generatedDirectory, "Assets"), { recursive: true })
  const manifest = JSON.parse(await readFile(join(templateDirectory, "icon.json"), "utf8"))
  manifest.fill = { "automatic-gradient": developmentIconColor.composer }
  await writeFile(join(generatedDirectory, "icon.json"), `${JSON.stringify(manifest, null, 2)}\n`)
  await cp(
    join(templateDirectory, "Assets", "icon-v2.svg"),
    join(generatedDirectory, "Assets", "icon-v2.svg")
  )
  return generatedDirectory
}

function run(repoRoot, environment, command, arguments_) {
  console.log(`\n$ ${command} ${arguments_.join(" ")}`)
  const child = spawn(command, arguments_, {
    cwd: repoRoot,
    env: environment,
    stdio: "inherit"
  })
  return waitForExit(child).then((result) => {
    if (result.code === 0) return
    throw new Error(`${command} failed (${describeExit(result)})`)
  })
}

function capture(repoRoot, environment, command, arguments_) {
  const child = spawn(command, arguments_, {
    cwd: repoRoot,
    env: environment,
    stdio: ["ignore", "pipe", "inherit"]
  })
  let output = ""
  child.stdout.setEncoding("utf8")
  child.stdout.on("data", (chunk) => {
    output += chunk
  })
  return waitForExit(child).then((result) => {
    if (result.code === 0) return output
    throw new Error(`${command} failed (${describeExit(result)})`)
  })
}

async function pathExists(path) {
  try {
    await access(path)
    return true
  } catch {
    return false
  }
}

function waitForExit(child) {
  if (child.exitCode !== null || child.signalCode !== null) {
    return Promise.resolve({ code: child.exitCode, signal: child.signalCode })
  }
  return new Promise((resolve) => {
    child.once("exit", (code, signal) => resolve({ code, signal }))
  })
}

function describeExit({ code, signal }) {
  return signal === null ? `code ${code ?? 1}` : `signal ${signal}`
}

function delay(milliseconds) {
  return new Promise((resolve) => setTimeout(resolve, milliseconds))
}
