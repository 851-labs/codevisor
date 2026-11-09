import { type ChildProcess, execFileSync, spawn } from "node:child_process"
import { readFile } from "node:fs/promises"
import { join, resolve } from "node:path"

import { delay } from "./child-processes.ts"
import type { CommandRunner } from "./commands.ts"
import type { DevelopmentLayout } from "./dev-layout.ts"
import { findAvailablePort, isPortAvailable, parsePort } from "./ports.ts"

export const CLOUD_WRANGLER_BUILD_CONDITIONS = "@codevisor/source,workerd,worker,browser"

export interface CloudDevInstance {
  readonly cloudExtraVariables: Array<string>
  readonly cloudPersistPath: string
  readonly cloudPort: number
  readonly cloudUrl: string
}

type Environment = Readonly<Record<string, string | undefined>>

const cloudPortBase = 41_000
const cloudPortRange = 10_000
const readinessAttempts = 120
const readinessPollMilliseconds = 250

export function cloudWranglerEnvironment(
  environment: Environment = process.env
): Record<string, string | undefined> {
  return { ...environment, WRANGLER_BUILD_CONDITIONS: CLOUD_WRANGLER_BUILD_CONDITIONS }
}

export async function readCloudDevVariables(
  repoRoot: string,
  capture?: CommandRunner["capture"]
): Promise<Record<string, string>> {
  for (const candidate of await devVariableFiles(repoRoot, capture)) {
    const content = await readFile(candidate, "utf8").catch(() => undefined)
    if (content !== undefined) return parseDevVariables(content)
  }
  return {}
}

export async function resolveCloudDevInstance(options: {
  readonly environment: Environment
  readonly instanceHash: string
  readonly layout: DevelopmentLayout
  readonly repoRoot: string
}): Promise<CloudDevInstance> {
  const variables = await readCloudDevVariables(options.repoRoot)
  const cloudPort = await cloudPortFor(options.environment, options.instanceHash)
  return {
    cloudExtraVariables: Object.entries(variables)
      .filter(([key]) => !key.startsWith("CODEVISOR_DEV_"))
      .flatMap(([key, value]) => ["--var", `${key}:${value}`]),
    cloudPersistPath: options.layout.wrangler,
    cloudPort,
    cloudUrl: `http://localhost:${cloudPort}`
  }
}

export async function applyCloudDevMigrations(options: {
  readonly cloudPersistPath: string
  readonly repoRoot: string
  readonly run: CommandRunner["run"]
}): Promise<void> {
  const migrate = [
    "x",
    "wrangler",
    "d1",
    "migrations",
    "apply",
    "codevisor-cloud",
    "--local",
    "--persist-to",
    options.cloudPersistPath
  ]
  await options
    .run("bun", migrate, join(options.repoRoot, "apps/cloud"))
    .catch((error: unknown) => {
      console.error(
        `Cloud dev migrations failed (${error instanceof Error ? error.message : String(error)})`
      )
    })
}

export function spawnCloudDev(options: {
  readonly cloud: CloudDevInstance
  readonly listensBeyondLoopback: boolean
  readonly repoRoot: string
  readonly worktreeName: string
}): ChildProcess {
  const { cloud } = options
  return spawn(
    "bun",
    [
      "x",
      "wrangler",
      "dev",
      ...(options.listensBeyondLoopback ? ["--ip", "0.0.0.0"] : []),
      "--port",
      String(cloud.cloudPort),
      "--persist-to",
      cloud.cloudPersistPath,
      "--var",
      "DEV_AUTH:1",
      "--var",
      `PUBLIC_BASE_URL:${cloud.cloudUrl}`,
      "--var",
      `HOOKS_BASE_URL:${cloud.cloudUrl}/hooks`,
      "--var",
      `INSTANCE_NAME:Codevisor Cloud (${options.worktreeName})`,
      ...cloud.cloudExtraVariables,
      "--show-interactive-dev-session=false"
    ],
    { cwd: join(options.repoRoot, "apps/cloud"), env: cloudWranglerEnvironment(), stdio: "inherit" }
  )
}

export async function prepareCloudSession(options: {
  readonly cloudProcess: ChildProcess
  readonly cloudUrl: string
  readonly sharedEnvironment: Record<string, string | undefined>
}): Promise<void> {
  try {
    if (!(await waitForCloud(options.cloudProcess, options.cloudUrl))) return

    options.sharedEnvironment.CODEVISOR_DEV_CLOUD_TOKEN = await devLoginToken(options.cloudUrl)
    console.log(
      `\nCloud dev instance ready at ${options.cloudUrl}\n  Dev account session handed to the app — sign in via "Use Development Account".\n  Device approvals: ${options.cloudUrl}/device\n`
    )
  } catch (error) {
    console.error(
      `Cloud dev instance unavailable (${error instanceof Error ? error.message : String(error)}); continuing without it.`
    )
  }
}

async function devVariableFiles(
  repoRoot: string,
  capture?: CommandRunner["capture"]
): Promise<Array<string>> {
  const candidates = [join(repoRoot, "apps/cloud/.dev.vars")]
  try {
    const mainRoot = resolve(repoRoot, (await gitCommonDir(repoRoot, capture)).trim(), "..")
    if (mainRoot !== repoRoot) candidates.push(join(mainRoot, "apps/cloud/.dev.vars"))
  } catch {}
  return candidates
}

async function gitCommonDir(repoRoot: string, capture?: CommandRunner["capture"]): Promise<string> {
  if (capture !== undefined) return capture("git", ["rev-parse", "--git-common-dir"])

  return execFileSync("git", ["rev-parse", "--git-common-dir"], { cwd: repoRoot, encoding: "utf8" })
}

function parseDevVariables(content: string): Record<string, string> {
  const variables: Record<string, string> = {}
  for (const line of content.split("\n")) {
    const trimmed = line.trim()
    const separator = trimmed.indexOf("=")
    if (trimmed === "" || trimmed.startsWith("#") || separator === -1) continue

    variables[trimmed.slice(0, separator).trim()] = trimmed
      .slice(separator + 1)
      .trim()
      .replace(/^"(.*)"$/, "$1")
  }
  return variables
}

async function cloudPortFor(environment: Environment, instanceHash: string): Promise<number> {
  const requested = parsePort(environment.CODEVISOR_DEV_CLOUD_PORT, "CODEVISOR_DEV_CLOUD_PORT")
  if (requested === undefined) {
    const preferred =
      cloudPortBase + (Number.parseInt(instanceHash.slice(0, 8), 16) % cloudPortRange)
    return findAvailablePort(preferred, cloudPortBase, cloudPortRange)
  }
  if (!(await isPortAvailable(requested))) {
    throw new Error(
      `CODEVISOR_DEV_CLOUD_PORT ${requested} is already in use; stop its owner or choose a different explicit port.`
    )
  }
  return requested
}

async function waitForCloud(cloudProcess: ChildProcess, cloudUrl: string): Promise<boolean> {
  for (let attempt = 0; attempt < readinessAttempts; attempt += 1) {
    if (cloudProcess.exitCode !== null) return false
    if (await isHealthy(`${cloudUrl}/health`)) return true

    await delay(readinessPollMilliseconds)
  }
  return true
}

async function isHealthy(url: string): Promise<boolean> {
  try {
    return (await fetch(url)).ok
  } catch {
    return false
  }
}

async function devLoginToken(cloudUrl: string): Promise<string> {
  const response = await fetch(`${cloudUrl}/dev/login`, { method: "POST" })
  if (!response.ok) throw new Error(`dev login returned ${response.status}`)

  const body: unknown = await response.json()
  if (!hasToken(body)) throw new Error("dev login returned no token")
  return body.token
}

function hasToken(body: unknown): body is { token: string } {
  return (
    typeof body === "object" && body !== null && "token" in body && typeof body.token === "string"
  )
}
