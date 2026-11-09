import { spawn } from "node:child_process"
import { rm } from "node:fs/promises"
import { join } from "node:path"

import { describeExit, waitForExit } from "./child-processes.ts"
import type { InstanceColor } from "./color.ts"
import { createDevelopmentAppIcon } from "./dev-icons.ts"
import type { DevelopmentLayout } from "./dev-layout.ts"
import {
  type SimulatorDependencies,
  requireIOSSimulator,
  type SimulatorManifest
} from "./ios-simulator-state.ts"
import { runXcodebuild } from "./xcodebuild.ts"

export interface IOSDevelopmentTarget {
  readonly simulator: SimulatorManifest
  readonly bundleIdentifier: string
  readonly appBundle: string
}

export async function buildIOSDevelopmentApp(options: {
  readonly repoRoot: string
  readonly layout: DevelopmentLayout
  readonly appDisplayName: string
  readonly bundleIdentifier: string
  readonly urlScheme: string
  readonly developmentIconColor: InstanceColor
  readonly simulatorDependencies: SimulatorDependencies
  readonly environment?: NodeJS.ProcessEnv
  readonly didSelectSimulator?: (simulator: SimulatorManifest) => void
}): Promise<IOSDevelopmentTarget> {
  const { repoRoot, layout } = options
  const simulator = await requireIOSSimulator(repoRoot, options.simulatorDependencies)
  options.didSelectSimulator?.(simulator)
  console.log(`  device:    ${simulator.name} (${simulator.runtime}) ${simulator.udid}`)

  const icon = await createDevelopmentAppIcon(repoRoot, options.developmentIconColor, "ios")
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
        `CODEVISOR_IOS_BUNDLE_IDENTIFIER=${options.bundleIdentifier}`,
        `CODEVISOR_URL_SCHEME=${options.urlScheme}`,
        `INFOPLIST_KEY_CFBundleDisplayName=${options.appDisplayName}`,
        "CODEVISOR_APP_ICON_NAME=AppIconDevGenerated",
        "build"
      ],
      { environment: options.environment ?? process.env, layout }
    )
  } finally {
    await rm(icon, { recursive: true, force: true })
  }
  return {
    simulator,
    bundleIdentifier: options.bundleIdentifier,
    appBundle: join(
      layout.build.ios.derivedData,
      "Build",
      "Products",
      "Debug-iphonesimulator",
      "Codevisor.app"
    )
  }
}

export async function launchIOSDevelopmentApp(options: {
  readonly repoRoot: string
  readonly target: IOSDevelopmentTarget
  readonly worktreeName: string
  readonly instanceName: string
  readonly developmentIconColor: InstanceColor
  readonly cloudURL?: string | undefined
  readonly netCaPem?: string | undefined
  readonly simulatorDependencies: SimulatorDependencies
  readonly environment?: NodeJS.ProcessEnv
}): Promise<void> {
  const { repoRoot, target, cloudURL } = options
  const environment = options.environment ?? process.env
  const { simulator, bundleIdentifier, appBundle } = target
  const current = await requireIOSSimulator(repoRoot, options.simulatorDependencies)
  if (current.lease !== simulator.lease)
    throw new Error("The worktree simulator changed during the build. Restart the dev runner.")

  await run(repoRoot, environment, "xcrun", ["simctl", "install", simulator.udid, appBundle])
  await waitForExit(
    spawn("xcrun", ["simctl", "terminate", simulator.udid, bundleIdentifier], {
      env: environment,
      stdio: "ignore"
    })
  )
  await run(repoRoot, launchEnvironment(environment, options), "xcrun", [
    "simctl",
    "launch",
    simulator.udid,
    bundleIdentifier
  ])
  console.log(launchSummary(simulator.name, cloudURL))
}

export async function terminateIOSDevelopmentApp(
  target: IOSDevelopmentTarget | undefined
): Promise<void> {
  if (target === undefined) return

  await waitForExit(
    spawn("xcrun", ["simctl", "terminate", target.simulator.udid, target.bundleIdentifier], {
      stdio: "ignore"
    })
  )
}

function launchEnvironment(
  environment: NodeJS.ProcessEnv,
  options: {
    worktreeName: string
    instanceName: string
    developmentIconColor: InstanceColor
    cloudURL?: string | undefined
    netCaPem?: string | undefined
  }
): NodeJS.ProcessEnv {
  return {
    ...environment,
    ...(options.cloudURL === undefined
      ? {}
      : { SIMCTL_CHILD_CODEVISOR_DEV_CLOUD_URL: options.cloudURL }),
    ...(options.netCaPem === undefined
      ? {}
      : { SIMCTL_CHILD_CODEVISOR_NET_CA_PEM: options.netCaPem }),
    SIMCTL_CHILD_TRANSCRIPT_STRESS: environment.TRANSCRIPT_STRESS ?? "0",
    SIMCTL_CHILD_CODEVISOR_DEV_WORKTREE: options.worktreeName,
    SIMCTL_CHILD_CODEVISOR_DEV_INSTANCE_ID: options.instanceName,
    SIMCTL_CHILD_CODEVISOR_DEV_ICON_COLOR: options.developmentIconColor.hex
  }
}

function launchSummary(simulatorName: string, cloudURL: string | undefined): string {
  if (cloudURL === undefined) {
    return `\nCodevisor iOS is running on ${simulatorName} without a dev cloud;\n  no machines are reachable until one is available.\n`
  }
  return `\nCodevisor iOS is running on ${simulatorName} against the dev cloud:\n  Cloud: ${cloudURL}\n  Sign in with "Use Development Account" to reach the dev machines.\n`
}

async function run(
  repoRoot: string,
  environment: NodeJS.ProcessEnv,
  command: string,
  args: ReadonlyArray<string>
): Promise<void> {
  console.log(`\n$ ${command} ${args.join(" ")}`)
  const result = await waitForExit(
    spawn(command, args, { cwd: repoRoot, env: environment, stdio: "inherit" })
  )
  if (result.code !== 0) throw new Error(`${command} failed (${describeExit(result)})`)
}
