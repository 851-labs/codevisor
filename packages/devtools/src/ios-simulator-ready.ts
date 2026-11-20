import { join } from "node:path"

import {
  iosProject,
  type SimulatorManifest,
  type SimulatorOptions,
  simulatorManifestPath
} from "./ios-simulator-state.ts"

export const xcodeWindowStillOpening =
  "project window still opening; the simulator does not wait for it"

export const simulatorStaysUp =
  "The simulator keeps running after this command exits; stop it with bun run ios-simulator --stop. Archiving the worktree (deleting its tmp/) also deletes it."

export function simulatorReadyBlock(manifest: SimulatorManifest): string {
  const repoRoot = manifest.repoRoot ?? ""
  return [
    `Simulator ready: ${manifest.name}`,
    `  Device: ${manifest.udid}`,
    `  Project: ${join(repoRoot, iosProject)}`,
    `  State: ${simulatorManifestPath(repoRoot)}`,
    `  Xcode: ${manifest.xcode ?? xcodeWindowStillOpening}`
  ].join("\n")
}

export function simulatorMatchesRequest(
  manifest: SimulatorManifest,
  options: SimulatorOptions
): boolean {
  return deviceMatches(manifest, options.device) && runtimeMatches(manifest, options.runtime)
}

export function simulatorMismatch(manifest: SimulatorManifest): string {
  const device = manifest.deviceName ?? manifest.deviceType ?? "another device"
  return `This worktree's simulator is already running as ${device} (${manifest.runtime ?? "unknown runtime"}). Stop it with bun run ios-simulator --stop, then start the one you want.`
}

function deviceMatches(manifest: SimulatorManifest, device: string | undefined): boolean {
  if (device === undefined) return true

  return device === manifest.deviceName || device === manifest.deviceType
}

function runtimeMatches(manifest: SimulatorManifest, runtime: string | undefined): boolean {
  if (runtime === undefined) return true

  const version = manifest.runtime?.replace(/^iOS /, "")
  return [manifest.runtimeIdentifier, manifest.runtime, version].includes(runtime)
}
