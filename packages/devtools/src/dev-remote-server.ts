import { type ChildProcess, spawn } from "node:child_process"
import { EventEmitter } from "node:events"
import { mkdir, readdir, readFile, writeFile } from "node:fs/promises"
import { dirname, join } from "node:path"

import { engineBinary, execEngine, tryEngine } from "./container-engine.ts"
import {
  type DevContainerContext,
  DEV_CONTAINER_IMAGE,
  devContainerName,
  devRemoteHomeMounts,
  WORKTREE_LABEL
} from "./dev-containers.ts"
import type { ServiceRoots } from "./dev-layout.ts"

export interface RemoteServerHandle {
  exitCode: number | null
  signalCode: NodeJS.Signals | null
  readonly once: (
    event: "exit",
    listener: (code: number | null, signal: NodeJS.Signals | null) => void
  ) => unknown
  readonly kill: () => boolean
}

export interface DevRemoteServerOptions {
  readonly containerContext: DevContainerContext | undefined
  readonly repoRoot: string
  readonly remoteRootHost: string
  readonly serverRoots: ServiceRoots
  readonly port: number
  readonly serverName: string
  readonly directPath: string | undefined
  readonly environment: Record<string, string | undefined>
}

const pollMilliseconds = 2_000
const missesBeforeExit = 3
const logLinesOnExit = 15

export async function launchDevRemoteServer(
  options: DevRemoteServerOptions
): Promise<ChildProcess | RemoteServerHandle> {
  const { containerContext, environment, serverRoots } = options
  const cloudUrl = rewriteHost(environment.CODEVISOR_DEV_CLOUD_URL, containerContext)
  if (cloudUrl !== undefined && (environment.CODEVISOR_DEV_CLOUD_TOKEN ?? "").length > 0) {
    await alignDevCloudCredentialUrl(join(serverRoots.data, "cloud.json"), cloudUrl)
  }
  if (containerContext === undefined) return spawnLocalServer(options)

  return startContainerServer(options, containerContext)
}

export async function alignDevCloudCredentialUrl(
  credentialsPath: string,
  serverUrl: string
): Promise<void> {
  const parsed = await readJsonObject(credentialsPath)
  if (parsed === undefined) return
  if (parsed.serverUrl !== serverUrl) {
    await writeFile(credentialsPath, `${JSON.stringify({ ...parsed, serverUrl }, null, 2)}\n`, {
      mode: 0o600
    })
  }

  const origin = serverUrl.replace(/\/+$/, "")
  const directory = join(dirname(credentialsPath), "shared-credentials")
  const names = await readdir(directory).catch(() => [])
  for (const name of names.filter((entry) => entry.endsWith(".json"))) {
    await rebindSharedCredential(join(directory, name), origin)
  }
}

function serveArguments(options: DevRemoteServerOptions, dataPath: string): Array<string> {
  return [
    "serve",
    "--serverId",
    options.environment.CODEVISOR_DEV_INSTANCE_ID ?? options.serverName,
    "--host",
    "0.0.0.0",
    "--port",
    String(options.port),
    "--db",
    `${dataPath}/codevisor-server.sqlite`,
    "--auth",
    "token",
    "--kind",
    "remote",
    ...(options.directPath === undefined ? [] : ["--direct-path", options.directPath]),
    "--name",
    options.serverName,
    "--upgrade-status",
    `${dataPath}/data-upgrade.json`
  ]
}

function spawnLocalServer(options: DevRemoteServerOptions): ChildProcess {
  return spawn(
    "node",
    [
      join(options.repoRoot, "apps/server/dist/main.js"),
      ...serveArguments(options, options.serverRoots.data)
    ],
    {
      cwd: options.repoRoot,
      env: options.environment,
      stdio: "inherit"
    }
  )
}

async function startContainerServer(
  options: DevRemoteServerOptions,
  context: DevContainerContext
): Promise<RemoteServerHandle> {
  const binary = engineBinary(context.engine)
  const containerName = devContainerName(options.serverName, context.worktreeHash)
  await tryEngine(binary, ["rm", "--force", containerName])
  const homeMounts = devRemoteHomeMounts(options.remoteRootHost)
  await Promise.all(homeMounts.map(({ host }) => mkdir(host, { recursive: true })))
  const toContainerPath = (hostPath: string) =>
    hostPath.replace(options.remoteRootHost, "/codevisor-data")
  await execEngine(binary, [
    "run",
    "--detach",
    "--cpus",
    "4",
    "--memory",
    "4g",
    "--name",
    containerName,
    "--label",
    `${WORKTREE_LABEL}=${context.worktreeHash}`,
    "--volume",
    `${context.appRoot}:/codevisor`,
    "--volume",
    `${context.stateRoot}:/codevisor-state`,
    "--volume",
    `${context.bunCache}:/codevisor-bun-cache`,
    ...homeMounts.flatMap(({ host, container }) => ["--volume", `${host}:${container}`]),
    "--volume",
    `${options.remoteRootHost}:/codevisor-data`,
    "--volume",
    `${context.entryScript}:/entry.sh`,
    "--volume",
    `${context.nativesCheck}:/natives-check.mjs`,
    "--volume",
    `${context.desktopScript}:/desktop.sh`,
    "--publish",
    `127.0.0.1:${options.port}:${options.port}`,
    "--env",
    "IS_SANDBOX=1",
    "--env",
    `CODEVISOR_DEV_DESKTOP=${context.desktop ? 1 : 0}`,
    ...containerEnvironment(options.environment, context, toContainerPath),
    DEV_CONTAINER_IMAGE,
    "sh",
    "/entry.sh",
    ...serveArguments(options, toContainerPath(options.serverRoots.data))
  ])
  console.log(`  container ${containerName} (${context.engine}) → 127.0.0.1:${options.port}`)
  return makeContainerHandle(binary, containerName)
}

function containerEnvironment(
  environment: Record<string, string | undefined>,
  context: DevContainerContext,
  toContainerPath: (hostPath: string) => string
): Array<string> {
  return Object.entries(environment).flatMap(([key, value]) => {
    if (!isProductVariable(key) || typeof value !== "string") return []

    const mapped =
      key === "CODEVISOR_DEV_CLOUD_URL"
        ? (rewriteHost(value, context) ?? value)
        : toContainerPath(value)
    return ["--env", `${key}=${mapped}`]
  })
}

function rewriteHost(
  value: string | undefined,
  context: DevContainerContext | undefined
): string | undefined {
  if (value === undefined || context === undefined) return value

  return value.replace("127.0.0.1", context.hostAddress).replace("localhost", context.hostAddress)
}

function isProductVariable(key: string): boolean {
  return key.startsWith("CODEVISOR_") || key.startsWith("HERDMAN_")
}

function makeContainerHandle(binary: string, name: string): RemoteServerHandle {
  const emitter = new EventEmitter()
  const handle: RemoteServerHandle = {
    exitCode: null,
    signalCode: null,
    once: (event, listener) => emitter.once(event, listener),
    kill: () => {
      void tryEngine(binary, ["rm", "--force", name])
      return true
    }
  }
  let misses = 0
  const poll = setInterval(() => {
    void checkContainer()
  }, pollMilliseconds)
  poll.unref()

  async function checkContainer(): Promise<void> {
    if (handle.exitCode !== null) return

    const inspected = await tryEngine(binary, ["inspect", name])
    misses = inspected?.includes('"running"') ? 0 : misses + 1
    if (misses < missesBeforeExit) return

    await reportStoppedContainer(binary, name)
    handle.exitCode = 0
    clearInterval(poll)
    emitter.emit("exit", 0, null)
  }
  return handle
}

async function reportStoppedContainer(binary: string, name: string): Promise<void> {
  console.error(`  container ${name} is no longer running; last log lines:`)
  const logs = await tryEngine(binary, ["logs", name])
  for (const line of logs?.split("\n").slice(-logLinesOnExit) ?? []) console.error(`    ${line}`)
}

async function rebindSharedCredential(path: string, origin: string): Promise<void> {
  const stored = await readJsonObject(path)
  const bound = typeof stored?.cloud === "string" ? parseUrl(stored.cloud) : undefined
  if (stored === undefined || bound === undefined || stored.cloud === origin) return

  const route = new URL(origin)
  if (bound.protocol !== route.protocol || bound.port !== route.port) return

  await writeFile(path, `${JSON.stringify({ ...stored, cloud: origin })}\n`, { mode: 0o600 })
}

function parseUrl(value: string): URL | undefined {
  try {
    return new URL(value)
  } catch {
    return undefined
  }
}

async function readJsonObject(path: string): Promise<Record<string, unknown> | undefined> {
  try {
    const parsed: unknown = JSON.parse(await readFile(path, "utf8"))
    return parsed !== null && typeof parsed === "object"
      ? Object.fromEntries(Object.entries(parsed))
      : undefined
  } catch {
    return undefined
  }
}
