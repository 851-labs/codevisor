// Containerized dev remotes: run Dev Direct and Dev Cloud as real Linux
// machines instead of same-host processes, so config-plane sync is tested
// across genuinely separate filesystems and operating systems.
//
// Constraints this module honors:
// - EVERYTHING repo-specific lives under the worktree's ignored tmp/ —
//   the Linux workspace copy, its node_modules, all server data. Deleting
//   the worktree (or tmp/) removes every trace. The only engine-global
//   artifact is the stock base image, shared like any brew package.
// - No custom image builds: a stock image plus bind mounts, so nothing
//   accumulates in the engine's image store.
// - Parallel worktrees stay isolated: container names and labels carry the
//   same per-worktree hash as ports and bundle identifiers.
import { spawn } from "node:child_process"
import type { ChildProcess } from "node:child_process"
import { EventEmitter } from "node:events"
import { mkdir, readFile, writeFile } from "node:fs/promises"
import { join } from "node:path"

import {
  containerHostAddress,
  DEV_CONTAINER_IMAGE,
  ensureDevContainerImage,
  execEngine,
  resolveContainerEngine,
  sweepStaleContainers,
  tryEngine,
  WORKTREE_LABEL
} from "./dev-container-engine.ts"
import type { DevContainerEngine } from "./dev-container-engine.ts"
import { syncLinuxWorkspace } from "./dev-container-workspace.ts"
import type { DevelopmentRoots } from "./dev-layout.ts"
import { pathExists } from "./dev-shared.ts"
// The engine half lives in dev-container-engine.ts; this stays the one module
// the dev runners import their whole container surface from.
export { containerHostAddress, DEV_CONTAINER_IMAGE, ensureDevContainerImage }
export { resolveContainerEngine, sweepStaleContainers, syncLinuxWorkspace }
export type { DevContainerEngine, EngineRunner } from "./dev-container-engine.ts"

/// One bind mount, in the `--volume host:container` sense.
export interface ContainerMount {
  host: string
  container: string
}

/// A dev remote server handle: a real child process in same-host mode, and
/// the ChildProcess-shaped container handle otherwise. Only container
/// remotes can read their connection token from inside the container.
export interface DevRemoteServer extends ChildProcess {
  readConnectionToken?: (() => Promise<string>) | undefined
}

export function devRemoteHomeMounts(remoteRootHost: string): ContainerMount[] {
  return [
    { host: join(remoteRootHost, ".container-home"), container: "/root" },
    { host: join(remoteRootHost, ".container-users"), container: "/home" }
  ]
}

export interface DevContainerPreparation {
  repoRoot: string
  containerRoot: string
  engine: DevContainerEngine
  worktreeHash: string
}

/// Everything a launched dev remote needs from the one-time preparation:
/// the engine it runs on, the assembled Linux workspace, the shared state
/// root, the entry script, and the address that reaches the host.
export interface DevContainerContext {
  engine: DevContainerEngine
  worktreeHash: string
  appRoot: string
  stateRoot: string
  entryScript: string
  hostAddress: string
}

/// One-time per-rig-start container preparation: assemble the Linux
/// workspace copy, make sure the stock image exists, sweep this worktree's
/// stale containers, and resolve the host address containers use to reach
/// the dev cloud hub.
export async function prepareDevContainers({
  repoRoot,
  containerRoot,
  engine,
  worktreeHash
}: DevContainerPreparation): Promise<DevContainerContext> {
  const stateRoot = join(containerRoot, "state")
  await mkdir(stateRoot, { recursive: true })
  const { appRoot, changed } = await syncLinuxWorkspace(repoRoot, containerRoot)
  await ensureDevContainerImage(engine)
  await sweepStaleContainers(engine, worktreeHash)
  const entryScript = join(repoRoot, "scripts", "dev-container-entry.sh")
  // The two server containers share this state and workspace; their first
  // boots would race the same bun download and node_modules install
  // (cross-VM file locks do not serialize virtiofs mounts). Provision
  // once, host-sequenced, before either server starts.
  if (changed || !(await pathExists(join(stateRoot, "installed.signature")))) {
    console.log("  provisioning Linux workspace (first container boot)…")
    const binary = engine === "apple" ? "container" : "docker"
    await execEngine(binary, [
      "run",
      "--rm",
      "--cpus",
      "4",
      "--memory",
      "4g",
      "--label",
      `${WORKTREE_LABEL}=${worktreeHash}`,
      "--volume",
      `${appRoot}:/codevisor`,
      "--volume",
      `${stateRoot}:/codevisor-state`,
      "--volume",
      `${entryScript}:/entry.sh`,
      DEV_CONTAINER_IMAGE,
      "sh",
      "/entry.sh",
      "--provision-only"
    ])
  }
  return {
    engine,
    worktreeHash,
    appRoot,
    stateRoot,
    entryScript,
    hostAddress: await containerHostAddress(engine)
  }
}

/// The hand-rolled container handle before it stands in for a ChildProcess.
interface ContainerServerHandle {
  exitCode: number | null
  signalCode: NodeJS.Signals | null
  once: (event: string, listener: (...args: unknown[]) => void) => EventEmitter
  kill: () => boolean
  readConnectionToken: () => Promise<string>
}

/// A ChildProcess-shaped handle for a detached container, so the callers'
/// existing waitForExit / waitForHealth / stop() logic works unchanged on
/// both modes. exitCode flips (and "exit" fires) when the container is
/// gone — it runs with --rm, so stopping and exiting look identical.
const makeContainerHandle = (binary: string, name: string, port: number): DevRemoteServer => {
  const emitter = new EventEmitter()
  const handle: ContainerServerHandle = {
    exitCode: null,
    signalCode: null,
    once: (event, listener) => emitter.once(event, listener),
    kill: () => {
      void tryEngine(binary, ["rm", "--force", name])
      return true
    },
    readConnectionToken: async () => {
      const script = [
        `const response = await fetch("http://127.0.0.1:${port}/v1/auth/connection-token")`,
        "if (!response.ok) throw new Error(`connection token returned ${response.status}`)",
        "process.stdout.write(await response.text())"
      ].join(";")
      const output = await execEngine(binary, [
        "exec",
        name,
        "node",
        "--input-type=module",
        "-e",
        script
      ])
      const parsed: { token?: unknown } = JSON.parse(output)
      if (typeof parsed.token !== "string" || parsed.token.length === 0) {
        throw new Error("Container returned an invalid development connection token")
      }
      return parsed.token
    }
  }
  let misses = 0
  const poll = setInterval(async () => {
    if (handle.exitCode !== null) return
    const inspected = await tryEngine(binary, ["inspect", name])
    const running = inspected !== undefined && inspected.includes('"running"')
    misses = running ? 0 : misses + 1
    if (misses >= 3) {
      console.error(`  container ${name} is no longer running; last log lines:`)
      const logs = await tryEngine(binary, ["logs", name])
      if (logs !== undefined) {
        for (const line of logs.split("\n").slice(-15)) console.error(`    ${line}`)
      }
      handle.exitCode = 0
      clearInterval(poll)
      emitter.emit("exit", 0, null)
    }
  }, 2_000)
  poll.unref()
  // The handle implements exactly the ChildProcess surface the dev runners
  // use (exitCode, signalCode, once("exit"), kill) and nothing else, so it
  // stands in for a real child process without being one.
  return handle as unknown as DevRemoteServer
}

/// A published container port is non-loopback from the server's perspective,
/// so the unauthenticated development token endpoint correctly rejects the
/// host request. Read it inside the container, where 127.0.0.1 really is the
/// server's loopback; same-host runners retain the ordinary fetch path.
export async function readDevRemoteConnectionToken(
  server: DevRemoteServer,
  serverUrl: string
): Promise<string> {
  if (typeof server.readConnectionToken === "function") return await server.readConnectionToken()
  const response = await fetch(`${serverUrl}/v1/auth/connection-token`)
  if (!response.ok) throw new Error(`connection token returned ${response.status}`)
  // fetch types the parsed body as `unknown`; the token check below is what
  // actually validates it.
  const parsed = (await response.json()) as { token?: unknown }
  if (typeof parsed.token !== "string" || parsed.token.length === 0) {
    throw new Error("Server returned an invalid development connection token")
  }
  return parsed.token
}

/// Dev remote state deliberately survives runner restarts, including its
/// machine API key. The route to the worktree-local cloud does not: it is
/// localhost in same-host mode and the VM gateway in container mode. Keep the
/// persisted credential pointed at the current route so its built-in validity
/// probe can either reuse the API key or re-provision it after a cloud reset.
export async function alignDevCloudCredentialUrl(
  credentialsPath: string,
  serverUrl: string
): Promise<void> {
  let parsed: Record<string, unknown> | null
  try {
    parsed = JSON.parse(await readFile(credentialsPath, "utf8"))
  } catch {
    return
  }
  if (parsed === null || typeof parsed !== "object" || parsed.serverUrl === serverUrl) return
  await writeFile(credentialsPath, `${JSON.stringify({ ...parsed, serverUrl }, null, 2)}\n`, {
    mode: 0o600
  })
}

export interface DevRemoteServerOptions {
  containerContext: DevContainerContext | undefined
  repoRoot: string
  remoteRootHost: string
  serverRoots: DevelopmentRoots
  port: number
  serverName: string
  directPath?: string | undefined
  environment: NodeJS.ProcessEnv
}

/// Launches one dev remote server in either mode, returning a
/// ChildProcess-compatible handle. Container mode runs the identical
/// `serve` command inside Linux, with the server's roots bind-mounted from
/// the worktree's tmp/ and dev-cloud URLs rewritten to the address the
/// container reaches the host at.
export async function launchDevRemoteServer({
  containerContext,
  repoRoot,
  remoteRootHost,
  serverRoots,
  port,
  serverName,
  directPath,
  environment
}: DevRemoteServerOptions): Promise<DevRemoteServer> {
  // A stable identity per dev remote: the default "local" server id
  // collides across the fleet's sync namespaces (every machine's
  // readiness would publish under the same key).
  const serverId = environment.CODEVISOR_DEV_INSTANCE_ID ?? serverName
  const rewriteHost = (value: string | undefined): string | undefined =>
    typeof value === "string" && containerContext !== undefined
      ? value
          .replace("127.0.0.1", containerContext.hostAddress)
          .replace("localhost", containerContext.hostAddress)
      : value
  const cloudUrl = rewriteHost(environment.CODEVISOR_DEV_CLOUD_URL)
  if (
    typeof cloudUrl === "string" &&
    typeof environment.CODEVISOR_DEV_CLOUD_TOKEN === "string" &&
    environment.CODEVISOR_DEV_CLOUD_TOKEN.length > 0
  ) {
    await alignDevCloudCredentialUrl(join(serverRoots.data, "cloud.json"), cloudUrl)
  }
  if (containerContext === undefined) {
    return spawn(
      "node",
      [
        join(repoRoot, "apps/server/dist/main.js"),
        "serve",
        "--serverId",
        serverId,
        "--host",
        "0.0.0.0",
        "--port",
        String(port),
        "--db",
        join(serverRoots.data, "codevisor-server.sqlite"),
        "--auth",
        "token",
        "--kind",
        "remote",
        ...(directPath === undefined ? [] : ["--direct-path", directPath]),
        "--name",
        serverName,
        "--upgrade-status",
        join(serverRoots.data, "data-upgrade.json")
      ],
      { cwd: repoRoot, env: environment, stdio: "inherit" }
    )
  }
  const { engine, worktreeHash, appRoot, stateRoot, entryScript } = containerContext
  const binary = engine === "apple" ? "container" : "docker"
  const toContainerPath = (hostPath: string): string =>
    hostPath.replace(remoteRootHost, "/codevisor-data")
  const containerName = `codevisor-dev-${serverName.toLowerCase().replace(/[^a-z0-9]+/g, "-")}-${worktreeHash.slice(0, 10)}`
  const env: Record<string, string | undefined> = {}
  for (const [key, value] of Object.entries(environment)) {
    if (!key.startsWith("CODEVISOR_") && !key.startsWith("HERDMAN_")) continue
    if (typeof value !== "string") continue
    env[key] = key === "CODEVISOR_DEV_CLOUD_URL" ? rewriteHost(value) : toContainerPath(value)
  }
  await tryEngine(binary, ["rm", "--force", containerName])
  // Harness credentials, installs, and user workspaces are machine state, not
  // shared cache. Keep both /root and /home per remote so container replacement
  // cannot silently delete a project's working directory.
  const homeMounts = devRemoteHomeMounts(remoteRootHost)
  await Promise.all(homeMounts.map(({ host }) => mkdir(host, { recursive: true })))
  const args = [
    "run",
    "--detach",
    // The first boot runs a full Linux workspace install; the engine's
    // default VM sizing is too small for that.
    "--cpus",
    "4",
    "--memory",
    "4g",
    "--name",
    containerName,
    "--label",
    `${WORKTREE_LABEL}=${worktreeHash}`,
    "--volume",
    `${appRoot}:/codevisor`,
    "--volume",
    `${stateRoot}:/codevisor-state`,
    ...homeMounts.flatMap(({ host, container }) => ["--volume", `${host}:${container}`]),
    "--volume",
    `${remoteRootHost}:/codevisor-data`,
    "--volume",
    `${entryScript}:/entry.sh`,
    "--publish",
    `127.0.0.1:${port}:${port}`,
    // The server runs as root in here, and Claude Code refuses
    // --dangerously-skip-permissions under root unless the process declares
    // a sandbox. This container IS one — without the flag every claude
    // session (capability inspection included) exits immediately.
    "--env",
    "IS_SANDBOX=1"
  ]
  for (const [key, value] of Object.entries(env)) args.push("--env", `${key}=${value}`)
  args.push(
    DEV_CONTAINER_IMAGE,
    "sh",
    "/entry.sh",
    "serve",
    "--serverId",
    serverId,
    "--host",
    "0.0.0.0",
    "--port",
    String(port),
    "--db",
    `${toContainerPath(serverRoots.data)}/codevisor-server.sqlite`,
    "--auth",
    "token",
    "--kind",
    "remote",
    ...(directPath === undefined ? [] : ["--direct-path", directPath]),
    "--name",
    serverName,
    "--upgrade-status",
    `${toContainerPath(serverRoots.data)}/data-upgrade.json`
  )
  await execEngine(binary, args)
  console.log(`  container ${containerName} (${engine}) → 127.0.0.1:${port}`)
  return makeContainerHandle(binary, containerName, port)
}
