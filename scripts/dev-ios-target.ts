import { spawn } from "node:child_process"
import type { ChildProcess } from "node:child_process"
import { cp, mkdir, readFile, rm, writeFile } from "node:fs/promises"
import { join } from "node:path"
import process from "node:process"

import type { DevelopmentLayout } from "./dev-layout.ts"
import type { ExitResult, WorktreeColor } from "./dev-shared.ts"
import { requireIOSSimulator } from "./ios-simulator-state.ts"
import type { SimulatorManifest } from "./ios-simulator-state.ts"
import { runXcodebuild } from "./xcodebuild.ts"

/// The spawn surface this module uses, so tests can inject a stand-in
/// without patching node:child_process (readonly under Bun).
export type SpawnProcess = typeof spawn

/// Resolves the simulator this worktree owns; injectable for the same reason.
export type RequireSimulator = (repoRoot: string) => Promise<SimulatorManifest>

/// A built iOS app plus the simulator it was built for.
export interface IOSDevelopmentTarget {
  simulator: SimulatorManifest
  bundleIdentifier: string
  appBundle: string
}

export interface BuildIOSDevelopmentAppOptions {
  repoRoot: string
  layout: DevelopmentLayout
  appDisplayName: string
  bundleIdentifier: string
  urlScheme: string
  developmentIconColor: WorktreeColor
  environment?: NodeJS.ProcessEnv | undefined
  didSelectSimulator?: ((simulator: SimulatorManifest) => void) | undefined
}

export interface LaunchIOSDevelopmentAppOptions {
  repoRoot: string
  target: IOSDevelopmentTarget
  environment?: NodeJS.ProcessEnv | undefined
  worktreeName: string
  instanceName: string
  developmentIconColor: WorktreeColor
  remoteHost: string
  remotePort: number
  remoteToken: string
  remoteName: string
  urlScheme: string
  cloudURL?: string | undefined
  requireSimulator?: RequireSimulator | undefined
  spawnProcess?: SpawnProcess | undefined
}

export interface TerminateIOSDevelopmentAppOptions {
  spawnProcess?: SpawnProcess | undefined
}

export async function buildIOSDevelopmentApp({
  repoRoot,
  layout,
  appDisplayName,
  bundleIdentifier,
  urlScheme,
  developmentIconColor,
  environment = process.env,
  didSelectSimulator
}: BuildIOSDevelopmentAppOptions): Promise<IOSDevelopmentTarget> {
  const simulator = await requireIOSSimulator(repoRoot)
  didSelectSimulator?.(simulator)
  console.log(`  device:    ${simulator.name} (${simulator.runtime}) ${simulator.udid}`)

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
  remoteHost,
  remotePort,
  remoteToken,
  remoteName,
  urlScheme,
  cloudURL,
  requireSimulator = requireIOSSimulator,
  spawnProcess = spawn
}: LaunchIOSDevelopmentAppOptions): Promise<void> {
  const { simulator, bundleIdentifier, appBundle } = target
  const current = await requireSimulator(repoRoot)
  if (current.lease !== simulator.lease)
    throw new Error("The worktree simulator changed during the build. Restart the dev runner.")
  await run(repoRoot, environment, "xcrun", ["simctl", "install", simulator.udid, appBundle], {
    spawnProcess
  })
  // A slow termination must finish before launch, or it can kill the new app.
  // A nonzero exit is expected when this is the first launch on the device.
  await waitForExit(
    spawnProcess("xcrun", ["simctl", "terminate", simulator.udid, bundleIdentifier], {
      env: environment,
      stdio: "ignore"
    })
  )

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
      SIMCTL_CHILD_TRANSCRIPT_STRESS: environment.TRANSCRIPT_STRESS ?? "0",
      SIMCTL_CHILD_CODEVISOR_DEV_WORKTREE: worktreeName,
      SIMCTL_CHILD_CODEVISOR_DEV_INSTANCE_ID: instanceName,
      SIMCTL_CHILD_CODEVISOR_DEV_ICON_COLOR: developmentIconColor.hex,
      SIMCTL_CHILD_CODEVISOR_DEV_REMOTE_HOST: remoteHost,
      SIMCTL_CHILD_CODEVISOR_DEV_REMOTE_PORT: String(remotePort),
      SIMCTL_CHILD_CODEVISOR_DEV_REMOTE_TOKEN: remoteToken,
      SIMCTL_CHILD_CODEVISOR_DEV_REMOTE_NAME: remoteName
    },
    "xcrun",
    ["simctl", "launch", simulator.udid, bundleIdentifier],
    { spawnProcess }
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

export async function terminateIOSDevelopmentApp(
  target: IOSDevelopmentTarget | undefined,
  { spawnProcess = spawn }: TerminateIOSDevelopmentAppOptions = {}
): Promise<void> {
  if (target === undefined) return
  await waitForExit(
    spawnProcess("xcrun", ["simctl", "terminate", target.simulator.udid, target.bundleIdentifier], {
      stdio: "ignore"
    })
  )
}

async function createDevelopmentAppIcon(
  repoRoot: string,
  developmentIconColor: WorktreeColor
): Promise<string> {
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
  const manifest: Record<string, unknown> = JSON.parse(
    await readFile(join(templateDirectory, "icon.json"), "utf8")
  )
  manifest.fill = { "automatic-gradient": developmentIconColor.composer }
  await writeFile(join(generatedDirectory, "icon.json"), `${JSON.stringify(manifest, null, 2)}\n`)
  await cp(
    join(templateDirectory, "Assets", "icon-v2.svg"),
    join(generatedDirectory, "Assets", "icon-v2.svg")
  )
  return generatedDirectory
}

function run(
  repoRoot: string,
  environment: NodeJS.ProcessEnv,
  command: string,
  arguments_: readonly string[],
  { spawnProcess = spawn }: TerminateIOSDevelopmentAppOptions = {}
): Promise<void> {
  console.log(`\n$ ${command} ${arguments_.join(" ")}`)
  const child = spawnProcess(command, arguments_, {
    cwd: repoRoot,
    env: environment,
    stdio: "inherit"
  })
  return waitForExit(child).then((result) => {
    if (result.code === 0) return
    throw new Error(`${command} failed (${describeExit(result)})`)
  })
}

function waitForExit(child: ChildProcess): Promise<ExitResult> {
  if (child.exitCode !== null || child.signalCode !== null) {
    return Promise.resolve({ code: child.exitCode, signal: child.signalCode })
  }
  return new Promise<ExitResult>((resolve) => {
    child.once("exit", (code, signal) => resolve({ code, signal }))
  })
}

function describeExit({ code, signal }: ExitResult): string {
  return signal === null ? `code ${code ?? 1}` : `signal ${signal}`
}
