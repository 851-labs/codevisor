// Shared plumbing for the Screen Sharing rig CLI: where the rig lives on each
// Mac, how this script shells out locally and over ssh, and how it reads back
// the files the rig itself wrote. Split out of screen-sharing-rig.ts so the
// install half and the inspect half can share it without importing each other.
import { spawnSync } from "node:child_process"
import { existsSync, readFileSync } from "node:fs"
import { homedir } from "node:os"
import { dirname, join } from "node:path"
import { fileURLToPath } from "node:url"

import { rigIdentity } from "./screen-sharing-bundle.ts"
import { quote, rigInstallDirectory, rigLaunchAgentLabel } from "./screen-sharing-rig-lib.ts"
import type { RigConfiguration, RigDeployRecord, RigPlan } from "./screen-sharing-rig-lib.ts"

export const root = dirname(dirname(fileURLToPath(import.meta.url)))
export const packagePath = join(root, "apps/screen-sharing-rig")
export const home = homedir()
export const installDirectory = join(home, rigInstallDirectory)
export const installedApp = join(installDirectory, rigIdentity.appName)
export const localConfigPath = join(installDirectory, "rig.json")
export const deployRecordPath = join(installDirectory, "deploy.json")
export const plistPath = join(home, "Library/LaunchAgents", `${rigLaunchAgentLabel}.plist`)
export const logDirectory = join(home, "Library/Logs/CodevisorRig")
export const buildApp = join(root, "tmp/screen-sharing", rigIdentity.appName)

export interface RunOptions {
  capture?: boolean
  input?: string
  allowFailure?: boolean
}

// Only a captured run has standard output to return.
export function run(
  commandName: string,
  args: readonly string[],
  options: RunOptions & { capture: true }
): string
export function run(
  commandName: string,
  args: readonly string[],
  options?: RunOptions
): string | undefined
export function run(
  commandName: string,
  args: readonly string[],
  { capture = false, input, allowFailure = false }: RunOptions = {}
): string | undefined {
  const result = spawnSync(commandName, args, {
    cwd: root,
    stdio: [input === undefined ? "inherit" : "pipe", capture ? "pipe" : "inherit", "inherit"],
    input,
    encoding: "utf8"
  })
  if (result.error) throw result.error
  if (result.status !== 0 && !allowFailure) {
    throw new Error(`${commandName} ${args.map(String).join(" ")} exited ${result.status}`)
  }
  return result.stdout?.trim()
}
export const runPlan = (plan: RigPlan) =>
  plan.forEach(([commandName, ...args]) => run(commandName, args))

export function writeRemoteFile(target: string, path: string, content: string): void {
  run(
    "ssh",
    ["-o", "BatchMode=yes", target, `mkdir -p ${quote(dirname(path))} && cat > ${quote(path)}`],
    { input: content }
  )
}

// The rig writes both files itself; the Swift parser is what validates rig.json.
export function readJSON<Contents>(path: string): Contents {
  return JSON.parse(readFileSync(path, "utf8")) as Contents
}
export function readLocalConfig(): RigConfiguration {
  if (!existsSync(localConfigPath))
    throw new Error(`No rig on this Mac yet: ${localConfigPath}. Run install first.`)
  return readJSON(localConfigPath)
}
export function readDeployRecord(): RigDeployRecord {
  if (!existsSync(deployRecordPath))
    throw new Error(`No deploy record: ${deployRecordPath}. Run install first.`)
  return readJSON(deployRecordPath)
}
