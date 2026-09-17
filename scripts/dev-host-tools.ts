import { execFileSync, spawn } from "node:child_process"
import { X509Certificate } from "node:crypto"
import { cp, mkdir, readFile, rm, writeFile } from "node:fs/promises"
import { join, resolve } from "node:path"
import process from "node:process"

import type { DevelopmentLayout } from "./dev-layout.ts"
import type { WorktreeColor } from "./dev-shared.ts"
import { describeExit, waitForExit } from "./dev-shared.ts"

/// Host-side tooling the dev runner shells out to: command runners, the
/// per-worktree app icon, browser extension icons, signing identities, and
/// the surgical termination of a previously launched dev app.

/// Runs a command to completion, inheriting stdio; rejects on a non-zero exit.
export type RunCommand = (
  command: string,
  arguments_: readonly string[],
  cwd?: string
) => Promise<void>

/// Runs a command and resolves with its stdout; rejects on a non-zero exit.
export type CaptureCommand = (command: string, arguments_: readonly string[]) => Promise<string>

export interface CommandRunner {
  capture: CaptureCommand
  run: RunCommand
}

/// `execFileSync` attaches the child's exit status to the error it throws.
type ExecFileSyncFailure = NodeJS.ErrnoException & { status?: number | null }

export function makeCommandRunner(repoRoot: string): CommandRunner {
  function run(command: string, arguments_: readonly string[], cwd = repoRoot): Promise<void> {
    console.log(`\n$ ${command} ${arguments_.join(" ")}`)
    const child = spawn(command, arguments_, { cwd, env: process.env, stdio: "inherit" })
    return waitForExit(child).then((result) => {
      if (result.code === 0) return
      throw new Error(`${command} failed (${describeExit(result)})`)
    })
  }

  function capture(command: string, arguments_: readonly string[]): Promise<string> {
    const child = spawn(command, arguments_, {
      cwd: repoRoot,
      env: process.env,
      stdio: ["ignore", "pipe", "inherit"]
    })
    let output = ""
    child.stdout.setEncoding("utf8")
    child.stdout.on("data", (chunk: string) => {
      output += chunk
    })
    return waitForExit(child).then((result) => {
      if (result.code === 0) return output
      throw new Error(`${command} failed (${describeExit(result)})`)
    })
  }

  return { capture, run }
}

// Locate apps/cloud/.dev.vars: this worktree first, then the main clone (via
// git's common dir), so per-developer cloud config is created once and shared
// by every worktree — including app-created ones. Returns {} when absent or
// git is unavailable; the cloud runs fine on dev login alone.
export async function readCloudDevVariables(repoRoot: string): Promise<Record<string, string>> {
  const candidates = [join(repoRoot, "apps/cloud/.dev.vars")]
  try {
    const commonDir = execFileSync("git", ["rev-parse", "--git-common-dir"], {
      cwd: repoRoot,
      encoding: "utf8"
    }).trim()
    const mainRoot = resolve(repoRoot, commonDir, "..")
    if (mainRoot !== repoRoot) candidates.push(join(mainRoot, "apps/cloud/.dev.vars"))
  } catch {
    // Not a git checkout (or git missing): worktree-local file only.
  }
  for (const candidate of candidates) {
    let content: string
    try {
      content = await readFile(candidate, "utf8")
    } catch {
      continue
    }
    const variables: Record<string, string> = {}
    for (const line of content.split("\n")) {
      const trimmed = line.trim()
      if (trimmed === "" || trimmed.startsWith("#")) continue
      const separator = trimmed.indexOf("=")
      if (separator === -1) continue
      variables[trimmed.slice(0, separator).trim()] = trimmed
        .slice(separator + 1)
        .trim()
        .replace(/^"(.*)"$/, "$1")
    }
    return variables
  }
  return {}
}

export async function createDevelopmentAppIcon(
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
    "macos",
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

export interface DevelopmentBrowserExtensionIconOptions {
  appName: string
  derivedDataPath: string
  layout: DevelopmentLayout
  run: RunCommand
}

export async function createDevelopmentBrowserExtensionIcons({
  appName,
  derivedDataPath,
  layout,
  run
}: DevelopmentBrowserExtensionIconOptions): Promise<string> {
  const iconsetDirectory = join(layout.build.generated, "BrowserExtensionDev.iconset")
  const compiledIcon = join(
    derivedDataPath,
    "Build",
    "Products",
    "Debug",
    `${appName}.app`,
    "Contents",
    "Resources",
    "AppIconDevGenerated.icns"
  )
  await rm(iconsetDirectory, { recursive: true, force: true })
  await run("iconutil", ["--convert", "iconset", "--output", iconsetDirectory, compiledIcon])
  return iconsetDirectory
}

export function terminateExactDevelopmentApp(executable: string): void {
  const pattern = `^${escapeRegularExpression(executable)}$`
  let processIDs: number[]
  try {
    processIDs = execFileSync("/usr/bin/pgrep", ["-f", pattern], { encoding: "utf8" })
      .trim()
      .split(/\s+/)
      .filter(Boolean)
      .map(Number)
  } catch (error) {
    if ((error as ExecFileSyncFailure | undefined)?.status === 1) return
    throw error
  }

  for (const processID of processIDs) {
    let command: string
    try {
      command = execFileSync("/bin/ps", ["-p", String(processID), "-o", "command="], {
        encoding: "utf8"
      }).trim()
    } catch (error) {
      if ((error as ExecFileSyncFailure | undefined)?.status === 1) continue
      throw error
    }
    if (command !== executable) continue
    try {
      process.kill(processID, "SIGTERM")
    } catch (error) {
      if ((error as NodeJS.ErrnoException | undefined)?.code !== "ESRCH") throw error
    }
  }
}

function escapeRegularExpression(value: string): string {
  return value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")
}

export async function resolveDevelopmentSigningArguments(
  capture: CaptureCommand
): Promise<string[]> {
  const identities = await capture("security", ["find-identity", "-v", "-p", "codesigning"])
  const match = identities.match(/[0-9]+\)\s+([0-9A-F]+)\s+"(Apple Development:[^"]+)"/)
  if (match === null) {
    console.warn(
      "\nNo Apple Development signing identity was found. This build will be ad-hoc signed, so macOS may require Accessibility permission again after a rebuild."
    )
    return []
  }
  // Both capture groups are mandatory in the pattern above, so a successful
  // match always carries them; the cast records that.
  const [, hash, identity] = match as [string, string, string]
  const certificate = await capture("security", ["find-certificate", "-c", identity, "-p"])
  const team = new X509Certificate(certificate).toLegacyObject().subject.OU
  if (typeof team !== "string" || team.length === 0) {
    console.warn(
      `\nThe ${identity} certificate has no signing team identifier. This build will be ad-hoc signed, so macOS may require Accessibility permission again after a rebuild.`
    )
    return []
  }
  console.log(`Using stable development signing identity ${hash} (${team})`)
  return [
    `CODE_SIGN_IDENTITY=${hash}`,
    `DEVELOPMENT_TEAM=${team}`,
    "CODE_SIGN_STYLE=Manual",
    "PROVISIONING_PROFILE_SPECIFIER="
  ]
}
