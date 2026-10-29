import { spawn } from "node:child_process"
import { rm } from "node:fs/promises"
import { join } from "node:path"
import process from "node:process"

import { createDevelopmentAppIcon } from "./dev-host-tools.mjs"
import { describeExit, waitForExit } from "./dev-shared.mjs"
import { requireIOSSimulator } from "./ios-simulator-state.mjs"
import { runXcodebuild } from "./xcodebuild.mjs"

export async function buildIOSDevelopmentApp({
  repoRoot,
  layout,
  appDisplayName,
  bundleIdentifier,
  urlScheme,
  developmentIconColor,
  environment = process.env,
  didSelectSimulator
}) {
  const simulator = await requireIOSSimulator(repoRoot)
  didSelectSimulator?.(simulator)
  console.log(`  device:    ${simulator.name} (${simulator.runtime}) ${simulator.udid}`)

  const generatedIconDirectory = await createDevelopmentAppIcon(
    repoRoot,
    developmentIconColor,
    "ios"
  )
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
        "CODEVISOR_APP_ICON_NAME=AppIconDevGenerated",
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
  cloudURL,
  netCaPem,
  requireSimulator = requireIOSSimulator
}) {
  const { simulator, bundleIdentifier, appBundle } = target
  const current = await requireSimulator(repoRoot)
  if (current.lease !== simulator.lease)
    throw new Error("The worktree simulator changed during the build. Restart the dev runner.")
  await run(repoRoot, environment, "xcrun", ["simctl", "install", simulator.udid, appBundle])
  await waitForExit(
    spawn("xcrun", ["simctl", "terminate", simulator.udid, bundleIdentifier], {
      env: environment,
      stdio: "ignore"
    })
  )

  const cloudEnvironment =
    cloudURL === undefined ? {} : { SIMCTL_CHILD_CODEVISOR_DEV_CLOUD_URL: cloudURL }
  const netEnvironment =
    netCaPem === undefined ? {} : { SIMCTL_CHILD_CODEVISOR_NET_CA_PEM: netCaPem }
  await run(
    repoRoot,
    {
      ...environment,
      ...cloudEnvironment,
      ...netEnvironment,
      SIMCTL_CHILD_TRANSCRIPT_STRESS: environment.TRANSCRIPT_STRESS ?? "0",
      SIMCTL_CHILD_CODEVISOR_DEV_WORKTREE: worktreeName,
      SIMCTL_CHILD_CODEVISOR_DEV_INSTANCE_ID: instanceName,
      SIMCTL_CHILD_CODEVISOR_DEV_ICON_COLOR: developmentIconColor.hex
    },
    "xcrun",
    ["simctl", "launch", simulator.udid, bundleIdentifier]
  )

  console.log("")
  if (cloudURL === undefined) {
    console.log(`Codevisor iOS is running on ${simulator.name} without a dev cloud;`)
    console.log("  no machines are reachable until one is available.")
  } else {
    console.log(`Codevisor iOS is running on ${simulator.name} against the dev cloud:`)
    console.log(`  Cloud: ${cloudURL}`)
    console.log(`  Sign in with "Use Development Account" to reach the dev machines.`)
  }
  console.log("")
}

export async function terminateIOSDevelopmentApp(target) {
  if (target === undefined) return
  await waitForExit(
    spawn("xcrun", ["simctl", "terminate", target.simulator.udid, target.bundleIdentifier], {
      stdio: "ignore"
    })
  )
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
