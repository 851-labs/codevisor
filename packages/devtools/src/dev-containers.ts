import { mkdir } from "node:fs/promises"
import { homedir } from "node:os"
import { join } from "node:path"

import { type ContainerEngine, engineBinary, execEngine, tryEngine } from "./container-engine.ts"
import { syncLinuxWorkspace } from "./dev-container-workspace.ts"
import { pathExists } from "./files.ts"

export const DEV_CONTAINER_IMAGE = "node:22-bookworm"
export const WORKTREE_LABEL = "dev.codevisor.worktree"

export interface DevContainerContext {
  readonly engine: ContainerEngine
  readonly worktreeHash: string
  readonly appRoot: string
  readonly stateRoot: string
  readonly bunCache: string
  readonly entryScript: string
  readonly nativesCheck: string
  readonly desktopScript: string
  readonly desktop: boolean
  readonly hostAddress: string
}

export interface HomeMount {
  readonly host: string
  readonly container: string
}

type Environment = Readonly<Record<string, string | undefined>>
type EngineRunner = (binary: string, args: ReadonlyArray<string>) => Promise<string | undefined>

const maxContainerNameLength = 63

export function devRemoteHomeMounts(remoteRootHost: string): Array<HomeMount> {
  return [
    { host: join(remoteRootHost, ".container-home"), container: "/root" },
    { host: join(remoteRootHost, ".container-users"), container: "/home" }
  ]
}

export function devContainerName(serverName: string, worktreeHash: string): string {
  const suffix = `-${worktreeHash.slice(0, 10)}`
  const slug = serverName.toLowerCase().replace(/[^a-z0-9]+/g, "-")
  const prefix = `codevisor-dev-${slug}`.slice(0, maxContainerNameLength - suffix.length)
  return `${prefix.replace(/-+$/, "")}${suffix}`
}

export function wantsContainerDesktop(environment: Environment = process.env): boolean {
  return environment.CODEVISOR_DEV_CONTAINER_DESKTOP === "1"
}

export function linuxBunCacheRoot(environment: Environment = process.env): string {
  return (
    environment.CODEVISOR_LINUX_BUN_CACHE ??
    join(homedir(), ".codevisor-development", "artifacts", "linux-bun-cache")
  )
}

export async function sweepStaleContainers(
  engine: ContainerEngine,
  worktreeHash: string,
  runEngine: EngineRunner = (binary, args) => tryEngine(binary, args, { timeout: 5_000 })
): Promise<void> {
  const listing =
    engine === "apple"
      ? ["list", "--all", "--format", "json"]
      : ["ps", "--all", "--format", "{{json .}}"]
  const raw = await runEngine(engineBinary(engine), listing)
  if (raw === undefined) return

  for (const entry of parseContainerEntries(raw)) {
    const id = staleContainerId(entry, worktreeHash)
    if (id !== undefined) await runEngine(engineBinary(engine), ["rm", "--force", id])
  }
}

export async function ensureDevContainerImage(engine: ContainerEngine): Promise<void> {
  const binary = engineBinary(engine)
  const inspect =
    engine === "apple"
      ? ["image", "list", "--format", "json"]
      : ["image", "inspect", DEV_CONTAINER_IMAGE]
  const listed = await tryEngine(binary, inspect)
  if (
    listed !== undefined &&
    (listed.includes('node:22-bookworm"') || listed.includes("22-bookworm "))
  )
    return

  console.log(`Pulling ${DEV_CONTAINER_IMAGE} (one-time, shared across worktrees)…`)
  await execEngine(binary, ["image", "pull", DEV_CONTAINER_IMAGE])
}

export async function containerHostAddress(engine: ContainerEngine): Promise<string> {
  if (engine === "docker") return "host.docker.internal"

  const parsed: unknown = JSON.parse(
    await execEngine("container", ["network", "inspect", "default"])
  )
  const gateway = gatewayOf(Array.isArray(parsed) ? parsed[0] : parsed)
  if (gateway === undefined)
    throw new Error("Could not determine the Apple container network gateway")
  return gateway
}

export async function prepareDevContainers(options: {
  readonly repoRoot: string
  readonly containerRoot: string
  readonly engine: ContainerEngine
  readonly worktreeHash: string
}): Promise<DevContainerContext> {
  const { repoRoot, containerRoot, engine, worktreeHash } = options
  const stateRoot = join(containerRoot, "state")
  const bunCache = linuxBunCacheRoot()
  await Promise.all([stateRoot, bunCache].map((directory) => mkdir(directory, { recursive: true })))
  const { appRoot, changed } = await syncLinuxWorkspace(repoRoot, containerRoot)
  await ensureDevContainerImage(engine)
  await sweepStaleContainers(engine, worktreeHash)
  const context = {
    engine,
    worktreeHash,
    appRoot,
    stateRoot,
    bunCache,
    entryScript: join(repoRoot, "scripts", "dev-container-entry.sh"),
    nativesCheck: join(repoRoot, "scripts", "dev-container-natives.mjs"),
    desktopScript: join(repoRoot, "scripts", "dev-container-desktop.sh"),
    desktop: wantsContainerDesktop(),
    hostAddress: await containerHostAddress(engine)
  }
  if (changed || !(await pathExists(join(stateRoot, "installed.signature"))))
    await provisionWorkspace(context)
  return context
}

async function provisionWorkspace(context: DevContainerContext): Promise<void> {
  console.log("  provisioning Linux workspace (first container boot)…")
  await execEngine(engineBinary(context.engine), [
    "run",
    "--rm",
    "--cpus",
    "4",
    "--memory",
    "4g",
    "--label",
    `${WORKTREE_LABEL}=${context.worktreeHash}`,
    "--volume",
    `${context.appRoot}:/codevisor`,
    "--volume",
    `${context.stateRoot}:/codevisor-state`,
    "--volume",
    `${context.bunCache}:/codevisor-bun-cache`,
    "--volume",
    `${context.entryScript}:/entry.sh`,
    "--volume",
    `${context.nativesCheck}:/natives-check.mjs`,
    DEV_CONTAINER_IMAGE,
    "sh",
    "/entry.sh",
    "--provision-only"
  ])
}

function parseContainerEntries(raw: string): Array<unknown> {
  try {
    const parsed: unknown = JSON.parse(raw)
    return Array.isArray(parsed) ? parsed : [parsed]
  } catch {
    return raw
      .split("\n")
      .filter((line) => line.trim().length > 0)
      .map((line): unknown => JSON.parse(line))
  }
}

function staleContainerId(entry: unknown, worktreeHash: string): string | undefined {
  const record = asRecord(entry)
  const configuration = asRecord(record.configuration)
  const labels = configuration.labels ?? record.Labels ?? {}
  if (!labelsMatch(labels, worktreeHash)) return undefined

  const id = configuration.id ?? record.ID ?? record.Names
  return typeof id === "string" && id.length > 0 ? id : undefined
}

function labelsMatch(labels: unknown, worktreeHash: string): boolean {
  if (typeof labels === "string")
    return labels.split(",").some((label) => label === `${WORKTREE_LABEL}=${worktreeHash}`)

  return asRecord(labels)[WORKTREE_LABEL] === worktreeHash
}

function gatewayOf(network: unknown): string | undefined {
  const gateway = asRecord(asRecord(network).status).ipv4Gateway
  return typeof gateway === "string" && gateway.length > 0 ? gateway : undefined
}

function asRecord(value: unknown): Record<string, unknown> {
  return value !== null && typeof value === "object"
    ? Object.fromEntries(Object.entries(value))
    : {}
}
