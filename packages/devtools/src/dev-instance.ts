import { createHash } from "node:crypto"
import { cp, mkdir, rm } from "node:fs/promises"
import { homedir } from "node:os"
import { basename, join } from "node:path"

import { colorFromHash, type InstanceColor } from "./color.ts"
import {
  type DevelopmentLayout,
  developmentLayout,
  iosDevelopmentBundleIdentifier
} from "./dev-layout.ts"
import { directoryIsEmpty, pathExists } from "./files.ts"
import { findAvailablePort, parsePort } from "./ports.ts"

export interface DevelopmentInstance {
  readonly appBundle: string
  readonly appExecutable: string
  readonly appName: string
  readonly appServerName: string
  readonly cloudRemoteName: string
  readonly cloudRemotePort: number
  readonly dataDirectory: string
  readonly derivedDataPath: string
  readonly developmentIconColor: InstanceColor
  readonly iOSBundleIdentifier: string
  readonly instanceHash: string
  readonly instanceName: string
  readonly layout: DevelopmentLayout
  readonly macOSBundleIdentifier: string
  readonly port: number
  readonly tmpRoot: string
  readonly urlScheme: string
  readonly worktreeName: string
  readonly worktreesDirectory: string
  readonly wwwPort: number
}

type Environment = Readonly<Record<string, string | undefined>>

const serverPorts = { base: 51_000, range: 10_000 }
const wwwPorts = { base: 61_000, range: 4_000 }

const ambientAllowlist = new Set([
  "CODEVISOR_DEV_PORT",
  "HERDMAN_DEV_PORT",
  "CODEVISOR_DEV_WWW_PORT",
  "CODEVISOR_DEV_CLOUD_PORT",
  "CODEVISOR_DEV_DATA_DIR",
  "CODEVISOR_DEV_LOGS_DIR",
  "CODEVISOR_DEV_CACHE_DIR",
  "HERDMAN_DEV_DATA_DIR",
  "CODEVISOR_WORKTREES_ROOT",
  "CODEVISOR_DEV_CONTAINER_ENGINE",
  "CODEVISOR_DEV_CONTAINER_DESKTOP",
  "HERDMAN_WORKTREES_ROOT",
  "CODEVISOR_REPOS_ROOT",
  "CODEVISOR_PLUGINS_ROOT",
  "CODEVISOR_GHOSTTY_ARTIFACTS_ROOT",
  "CODEVISOR_GHOSTTY_ARTIFACT_ORIGIN",
  "CODEVISOR_SCREEN_SHARING_STATS_LOG",
  "CODEVISOR_VERSION",
  "HERDMAN_VERSION"
])

export function sanitizeAmbientEnvironment(environment: Record<string, string | undefined>): void {
  for (const key of Object.keys(environment)) {
    if (isProductVariable(key) && !ambientAllowlist.has(key)) delete environment[key]
  }
}

export async function resolveDevelopmentInstance(
  repoRoot: string,
  environment: Environment
): Promise<DevelopmentInstance> {
  const worktreeName = basename(repoRoot)
  const instanceHash = createHash("sha256").update(repoRoot).digest("hex").slice(0, 10)
  const appName = `Codevisor (${worktreeName})`
  const layout = developmentLayout(repoRoot)
  const derivedDataPath = layout.build.macos.derivedData
  const appBundle = join(derivedDataPath, "Build", "Products", "Debug", `${appName}.app`)
  const port = await serverPort(environment, instanceHash)
  return {
    appBundle,
    appExecutable: join(appBundle, "Contents", "MacOS", appName),
    appName,
    appServerName: `Mac App (${worktreeName})`,
    cloudRemoteName: `Dev Cloud (${worktreeName})`,
    cloudRemotePort: await findAvailablePort(port + 2, serverPorts.base, serverPorts.range),
    dataDirectory: layout.local.data,
    derivedDataPath,
    developmentIconColor: colorFromHash(createHash("sha256").update(worktreeName).digest("hex")),
    iOSBundleIdentifier: iosDevelopmentBundleIdentifier(repoRoot),
    instanceHash,
    instanceName: `${worktreeName}-${instanceHash}`,
    layout,
    macOSBundleIdentifier: `com.851labs.Codevisor.Development.${instanceHash}`,
    port,
    tmpRoot: layout.tmpRoot,
    urlScheme: `codevisor-dev-${instanceHash}`,
    worktreeName,
    worktreesDirectory: layout.local.worktrees,
    wwwPort: await wwwPort(environment, instanceHash)
  }
}

export async function migrateLegacyDevelopmentState(
  instance: DevelopmentInstance,
  repoRoot: string
): Promise<void> {
  const { dataDirectory, layout } = instance
  if (dataDirectory !== layout.local.data || !(await directoryIsEmpty(dataDirectory))) return

  for (const previous of legacyStateLocations(instance, repoRoot)) {
    if (!(await holdsLegacyState(previous, instance.tmpRoot))) continue

    console.log(`Moving dev state into ${dataDirectory}`)
    await rm(dataDirectory, { recursive: true, force: true })
    await mkdir(layout.local.root, { recursive: true })
    await cp(previous, dataDirectory, { recursive: true })
    await rm(previous, { recursive: true, force: true })
    return
  }
}

function isProductVariable(key: string): boolean {
  return key.startsWith("CODEVISOR_") || key.startsWith("HERDMAN_")
}

async function serverPort(environment: Environment, instanceHash: string): Promise<number> {
  const requested = parsePort(
    environment.CODEVISOR_DEV_PORT ?? environment.HERDMAN_DEV_PORT,
    "CODEVISOR_DEV_PORT"
  )
  return (
    requested ??
    findAvailablePort(preferredPort(instanceHash, serverPorts), serverPorts.base, serverPorts.range)
  )
}

async function wwwPort(environment: Environment, instanceHash: string): Promise<number> {
  const requested = parsePort(environment.CODEVISOR_DEV_WWW_PORT, "CODEVISOR_DEV_WWW_PORT")
  return (
    requested ??
    findAvailablePort(preferredPort(instanceHash, wwwPorts), wwwPorts.base, wwwPorts.range)
  )
}

function preferredPort(instanceHash: string, ports: { base: number; range: number }): number {
  return ports.base + (Number.parseInt(instanceHash.slice(0, 8), 16) % ports.range)
}

function legacyStateLocations(instance: DevelopmentInstance, repoRoot: string): Array<string> {
  return [
    join(instance.tmpRoot, "codevisor"),
    join(repoRoot, ".codevisor"),
    join(
      homedir(),
      "Library",
      "Application Support",
      "Codevisor Development",
      instance.instanceName
    )
  ]
}

async function holdsLegacyState(previous: string, tmpRoot: string): Promise<boolean> {
  if (!(await pathExists(previous))) return false
  if (previous !== join(tmpRoot, "codevisor")) return true

  return pathExists(join(previous, "codevisor-server.sqlite"))
}
