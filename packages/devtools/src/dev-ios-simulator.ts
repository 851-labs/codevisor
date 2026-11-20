import { parseDevelopmentRunnerArguments } from "./dev-arguments.ts"
import { ensureIOSSimulator, type SimulatorLauncherDependencies } from "./ios-simulator-launcher.ts"
import {
  defaultSimulatorDevice,
  parseSimulatorArguments,
  type SimulatorManifest
} from "./ios-simulator-state.ts"

const staysUp =
  "It stays up when dev:ios stops, so later runs reuse it; remove it with bun run ios-simulator --stop."

export async function prepareDevelopmentSimulator(
  repoRoot: string,
  runnerArguments: ReadonlyArray<string>,
  dependencies: SimulatorLauncherDependencies
): Promise<boolean> {
  if (!runsIOS(runnerArguments)) return true

  const outcome = await ensureIOSSimulator(repoRoot, parseSimulatorArguments([]), dependencies)
  if (outcome.kind === "failed") {
    ;(dependencies.write ?? writeToStderr)(`${outcome.reason}\n`)
    return false
  }

  if (outcome.kind === "started")
    report(dependencies, `Started this worktree's simulator. ${staysUp}\n`)
  else report(dependencies, `${reuseNotice(outcome.manifest)}\n`)
  return true
}

function runsIOS(runnerArguments: ReadonlyArray<string>): boolean {
  try {
    return parseDevelopmentRunnerArguments(runnerArguments).target === "ios"
  } catch {
    return false
  }
}

function reuseNotice(manifest: SimulatorManifest): string {
  const device = manifest.deviceName ?? manifest.deviceType ?? "unknown device"
  const reusing = `Reusing this worktree's simulator: ${device}, ${manifest.runtime ?? "unknown runtime"} (${manifest.udid}). ${staysUp}`
  if (device === defaultSimulatorDevice) return reusing

  return `${reusing} It is not the default ${defaultSimulatorDevice} because bun run ios-simulator started it with another device; dev:ios uses it as it is. To get the default, stop it first.`
}

function report(dependencies: SimulatorLauncherDependencies, text: string): void {
  ;(dependencies.write ?? writeToStdout)(text)
}

function writeToStderr(text: string): void {
  process.stderr.write(text)
}

function writeToStdout(text: string): void {
  process.stdout.write(text)
}
