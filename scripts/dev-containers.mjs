import { execFile, spawn } from "node:child_process"
import { EventEmitter } from "node:events"
import { mkdir, readdir, readFile, writeFile } from "node:fs/promises"
import { homedir } from "node:os"
import { dirname, join } from "node:path"

import { syncLinuxWorkspace } from "./dev-container-workspace.mjs"
import { pathExists } from "./dev-shared.mjs"

export function devRemoteHomeMounts(remoteRootHost) {
  return [
    { host: join(remoteRootHost, ".container-home"), container: "/root" },
    { host: join(remoteRootHost, ".container-users"), container: "/home" }
  ]
}

const execEngine = (binary, args, options = {}) =>
  new Promise((resolve, reject) => {
    execFile(binary, args, { maxBuffer: 16 * 1024 * 1024, ...options }, (error, stdout, stderr) => {
      if (error) {
        reject(new Error(`${binary} ${args.join(" ")} failed: ${stderr || error.message}`))
        return
      }
      resolve(stdout)
    })
  })

const tryEngine = async (binary, args, options) => {
  try {
    return await execEngine(binary, args, options)
  } catch {
    return undefined
  }
}

const appleContainerEngine = async () => {
  const version = await tryEngine("container", ["--version"])
  if (version === undefined) return undefined
  const match = /version (\d+)\./.exec(version)
  if (match === null || Number(match[1]) < 1) {
    console.warn(
      `Apple container CLI ${version.trim()} is too old for dev containers; install 1.x: brew install container`
    )
    return undefined
  }
  if ((await tryEngine("container", ["system", "start"])) === undefined) return undefined
  return "apple"
}

const dockerEngine = async () =>
  (await tryEngine("docker", ["version", "--format", "{{.Server.Version}}"])) === undefined
    ? undefined
    : "docker"

export async function resolveContainerEngine(preference) {
  const wanted = preference ?? process.env.CODEVISOR_DEV_CONTAINER_ENGINE ?? "auto"
  if (wanted === "none") return undefined
  if (wanted === "apple") return await appleContainerEngine()
  if (wanted === "docker") return await dockerEngine()
  return (await appleContainerEngine()) ?? (await dockerEngine())
}

const WORKTREE_LABEL = "dev.codevisor.worktree"

const parseContainerEntries = (raw) => {
  try {
    const parsed = JSON.parse(raw)
    return Array.isArray(parsed) ? parsed : [parsed]
  } catch {
    return raw
      .split("\n")
      .filter((line) => line.trim().length > 0)
      .map((line) => JSON.parse(line))
  }
}

const staleContainerId = (entry, worktreeHash) => {
  const labels = entry.configuration?.labels ?? entry.Labels ?? {}
  const matches =
    typeof labels === "string"
      ? labels.split(",").some((label) => label === `${WORKTREE_LABEL}=${worktreeHash}`)
      : labels[WORKTREE_LABEL] === worktreeHash
  if (!matches) return undefined
  const id = entry.configuration?.id ?? entry.ID ?? entry.Names
  if (typeof id !== "string" || id.length === 0) return undefined
  return id
}

export async function sweepStaleContainers(
  engine,
  worktreeHash,
  runEngine = (binary, args) => tryEngine(binary, args, { timeout: 5_000 })
) {
  const raw = await runEngine(
    engine === "apple" ? "container" : "docker",
    engine === "apple"
      ? ["list", "--all", "--format", "json"]
      : ["ps", "--all", "--format", "{{json .}}"]
  )
  if (raw === undefined) return
  for (const entry of parseContainerEntries(raw)) {
    const id = staleContainerId(entry, worktreeHash)
    if (id === undefined) continue
    await runEngine(engine === "apple" ? "container" : "docker", ["rm", "--force", id])
  }
}

export const DEV_CONTAINER_IMAGE = "node:22-bookworm"

export function linuxBunCacheRoot(environment = process.env) {
  return (
    environment.CODEVISOR_LINUX_BUN_CACHE ??
    join(homedir(), ".codevisor-development", "artifacts", "linux-bun-cache")
  )
}

export async function ensureDevContainerImage(engine) {
  const binary = engine === "apple" ? "container" : "docker"
  const listed = await tryEngine(
    binary,
    engine === "apple"
      ? ["image", "list", "--format", "json"]
      : ["image", "inspect", DEV_CONTAINER_IMAGE]
  )
  if (
    listed !== undefined &&
    (listed.includes('node:22-bookworm"') || listed.includes("22-bookworm "))
  )
    return
  console.log(`Pulling ${DEV_CONTAINER_IMAGE} (one-time, shared across worktrees)…`)
  await execEngine(binary, ["image", "pull", DEV_CONTAINER_IMAGE])
}

export async function containerHostAddress(engine) {
  if (engine === "docker") return "host.docker.internal"
  const raw = await execEngine("container", ["network", "inspect", "default"])
  const parsed = JSON.parse(raw)
  const network = Array.isArray(parsed) ? parsed[0] : parsed
  const gateway = network?.status?.ipv4Gateway
  if (typeof gateway !== "string" || gateway.length === 0) {
    throw new Error("Could not determine the Apple container network gateway")
  }
  return gateway
}

const MAX_CONTAINER_NAME_LENGTH = 63

export const devContainerName = (serverName, worktreeHash) => {
  const suffix = `-${worktreeHash.slice(0, 10)}`
  const slug = serverName.toLowerCase().replace(/[^a-z0-9]+/g, "-")
  const prefix = `codevisor-dev-${slug}`.slice(0, MAX_CONTAINER_NAME_LENGTH - suffix.length)
  return `${prefix.replace(/-+$/, "")}${suffix}`
}

export const wantsContainerDesktop = (environment = process.env) =>
  environment.CODEVISOR_DEV_CONTAINER_DESKTOP === "1"

export async function prepareDevContainers({ repoRoot, containerRoot, engine, worktreeHash }) {
  const stateRoot = join(containerRoot, "state")
  const bunCache = linuxBunCacheRoot()
  await Promise.all([stateRoot, bunCache].map((d) => mkdir(d, { recursive: true })))
  const { appRoot, changed } = await syncLinuxWorkspace(repoRoot, containerRoot)
  await ensureDevContainerImage(engine)
  await sweepStaleContainers(engine, worktreeHash)
  const entryScript = join(repoRoot, "scripts", "dev-container-entry.sh")
  const nativesCheck = join(repoRoot, "scripts", "dev-container-natives.mjs")
  const desktopScript = join(repoRoot, "scripts", "dev-container-desktop.sh")
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
      `${bunCache}:/codevisor-bun-cache`,
      "--volume",
      `${entryScript}:/entry.sh`,
      "--volume",
      `${nativesCheck}:/natives-check.mjs`,
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
    bunCache,
    entryScript,
    nativesCheck,
    desktopScript,
    desktop: wantsContainerDesktop(),
    hostAddress: await containerHostAddress(engine)
  }
}

const makeContainerHandle = (binary, name) => {
  const emitter = new EventEmitter()
  const handle = {
    exitCode: null,
    signalCode: null,
    once: (event, listener) => emitter.once(event, listener),
    kill: () => {
      void tryEngine(binary, ["rm", "--force", name])
      return true
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
  return handle
}

export async function alignDevCloudCredentialUrl(credentialsPath, serverUrl) {
  const parsed = await readJsonObject(credentialsPath)
  if (parsed === undefined) return
  if (parsed.serverUrl !== serverUrl) {
    await writeFile(credentialsPath, `${JSON.stringify({ ...parsed, serverUrl }, null, 2)}\n`, {
      mode: 0o600
    })
  }
  const origin = serverUrl.replace(/\/+$/, "")
  const route = new URL(origin)
  const directory = join(dirname(credentialsPath), "shared-credentials")
  let names
  try {
    names = await readdir(directory)
  } catch {
    return
  }
  for (const name of names.filter((entry) => entry.endsWith(".json"))) {
    const path = join(directory, name)
    const stored = await readJsonObject(path)
    if (typeof stored?.cloud !== "string" || stored.cloud === origin) continue
    let bound
    try {
      bound = new URL(stored.cloud)
    } catch {
      continue
    }
    if (bound.protocol !== route.protocol || bound.port !== route.port) continue
    await writeFile(path, `${JSON.stringify({ ...stored, cloud: origin })}\n`, { mode: 0o600 })
  }
}

const readJsonObject = async (path) => {
  try {
    const parsed = JSON.parse(await readFile(path, "utf8"))
    return parsed !== null && typeof parsed === "object" ? parsed : undefined
  } catch {
    return undefined
  }
}

export async function launchDevRemoteServer({
  containerContext,
  repoRoot,
  remoteRootHost,
  serverRoots,
  port,
  serverName,
  directPath,
  environment
}) {
  const serverId = environment.CODEVISOR_DEV_INSTANCE_ID ?? serverName
  const rewriteHost = (value) =>
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
  const {
    engine,
    worktreeHash,
    appRoot,
    stateRoot,
    bunCache,
    entryScript,
    nativesCheck,
    desktopScript,
    desktop
  } = containerContext
  const binary = engine === "apple" ? "container" : "docker"
  const toContainerPath = (hostPath) => hostPath.replace(remoteRootHost, "/codevisor-data")
  const containerName = devContainerName(serverName, worktreeHash)
  const env = {}
  for (const [key, value] of Object.entries(environment)) {
    if (!key.startsWith("CODEVISOR_") && !key.startsWith("HERDMAN_")) continue
    if (typeof value !== "string") continue
    env[key] = key === "CODEVISOR_DEV_CLOUD_URL" ? rewriteHost(value) : toContainerPath(value)
  }
  await tryEngine(binary, ["rm", "--force", containerName])
  const homeMounts = devRemoteHomeMounts(remoteRootHost)
  await Promise.all(homeMounts.map(({ host }) => mkdir(host, { recursive: true })))
  const args = [
    "run",
    "--detach",
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
    "--volume",
    `${bunCache}:/codevisor-bun-cache`,
    ...homeMounts.flatMap(({ host, container }) => ["--volume", `${host}:${container}`]),
    "--volume",
    `${remoteRootHost}:/codevisor-data`,
    "--volume",
    `${entryScript}:/entry.sh`,
    "--volume",
    `${nativesCheck}:/natives-check.mjs`,
    "--volume",
    `${desktopScript}:/desktop.sh`,
    "--publish",
    `127.0.0.1:${port}:${port}`,
    "--env",
    "IS_SANDBOX=1",
    "--env",
    `CODEVISOR_DEV_DESKTOP=${desktop ? 1 : 0}`
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
  return makeContainerHandle(binary, containerName)
}
