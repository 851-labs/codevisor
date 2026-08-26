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
import { execFile, spawn } from "node:child_process"
import { EventEmitter } from "node:events"
import { createHash } from "node:crypto"
import { cp, mkdir, readdir, readFile, rm, stat, writeFile } from "node:fs/promises"
import { join } from "node:path"
import { pathExists } from "./dev-shared.mjs"

/// The workspace subset a Linux container needs to run `dist/main.js`:
/// built output plus manifests, never sources or macOS node_modules. The
/// container installs its own Linux node_modules into the copy.
const WORKSPACE_ROOTS = ["packages", "apps"]
const PACKAGE_KEEP = ["package.json", "dist"]
const ROOT_KEEP = ["package.json", "bun.lock", "bun.lockb", ".npmrc", "bunfig.toml", "patches"]

const copyIfPresent = async (from, to) => {
  if (!(await pathExists(from))) return false
  await cp(from, to, { recursive: true, force: true })
  return true
}

const workspacePackageDirectories = async (repoRoot) => {
  const directories = []
  for (const root of WORKSPACE_ROOTS) {
    const rootPath = join(repoRoot, root)
    if (!(await pathExists(rootPath))) continue
    for (const entry of await readdir(rootPath, { withFileTypes: true })) {
      if (!entry.isDirectory()) continue
      if (await pathExists(join(rootPath, entry.name, "package.json"))) {
        directories.push(join(root, entry.name))
      }
    }
  }
  return directories
}

/// A cheap change signature over every manifest and dist mtime: when it
/// matches the previous sync, the copy (and the container's install) can be
/// skipped entirely, so rig restarts stay fast.
const workspaceSignature = async (repoRoot, packageDirectories) => {
  const hash = createHash("sha256")
  for (const name of ROOT_KEEP) {
    const path = join(repoRoot, name)
    if (!(await pathExists(path))) continue
    hash.update(name)
    hash.update(await readFile(path))
  }
  for (const directory of packageDirectories.toSorted()) {
    hash.update(directory)
    hash.update(await readFile(join(repoRoot, directory, "package.json")))
    const dist = join(repoRoot, directory, "dist")
    if (await pathExists(dist)) {
      const newest = await newestMtime(dist)
      hash.update(String(newest))
    }
  }
  return hash.digest("hex")
}

const newestMtime = async (path) => {
  const info = await stat(path)
  if (!info.isDirectory()) return info.mtimeMs
  let newest = info.mtimeMs
  for (const entry of await readdir(path)) {
    newest = Math.max(newest, await newestMtime(join(path, entry)))
  }
  return newest
}

/// Assembles (or refreshes) the Linux workspace copy under
/// tmp/container/app. Returns the absolute path to the copy.
export async function syncLinuxWorkspace(repoRoot, containerRoot) {
  const appRoot = join(containerRoot, "app")
  const packageDirectories = await workspacePackageDirectories(repoRoot)
  const signature = await workspaceSignature(repoRoot, packageDirectories)
  const signaturePath = join(containerRoot, "app.signature")
  const previous = (await pathExists(signaturePath))
    ? await readFile(signaturePath, "utf8")
    : undefined
  if (previous === signature && (await pathExists(join(appRoot, "package.json")))) {
    return { appRoot, changed: false }
  }
  await mkdir(appRoot, { recursive: true })
  for (const name of ROOT_KEEP) {
    await copyIfPresent(join(repoRoot, name), join(appRoot, name))
  }
  for (const directory of packageDirectories) {
    const target = join(appRoot, directory)
    // Stale dist output must not survive a package rename/removal.
    await rm(target, { recursive: true, force: true })
    await mkdir(target, { recursive: true })
    for (const name of PACKAGE_KEEP) {
      await copyIfPresent(join(repoRoot, directory, name), join(target, name))
    }
  }
  await writeFile(signaturePath, signature)
  return { appRoot, changed: true }
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

const tryEngine = async (binary, args) => {
  try {
    return await execEngine(binary, args)
  } catch {
    return undefined
  }
}

/// Picks the container engine: Apple's `container` (lightweight VMs,
/// Apple-silicon-optimized, no desktop daemon) is preferred; Docker (or
/// OrbStack's docker CLI) is the fallback; `undefined` means run the dev
/// remotes as same-host processes exactly as before. Selection is
/// overridable with --container-engine=apple|docker|none or
/// CODEVISOR_DEV_CONTAINER_ENGINE. Never boots a stopped Docker daemon —
/// that would be exactly the "gets in the way" this feature must avoid;
/// Apple's headless service is started on demand (it is the whole point
/// of asking for containers).
export async function resolveContainerEngine(preference) {
  const wanted = preference ?? process.env.CODEVISOR_DEV_CONTAINER_ENGINE ?? "auto"
  if (wanted === "none") return undefined
  const apple = async () => {
    const version = await tryEngine("container", ["--version"])
    if (version === undefined) return undefined
    const match = /version (\d+)\./.exec(version)
    if (match === null || Number(match[1]) < 1) {
      console.warn(
        `Apple container CLI ${version.trim()} is too old for dev containers; install 1.x: brew install container`
      )
      return undefined
    }
    // Starting the service is idempotent and headless.
    if ((await tryEngine("container", ["system", "start"])) === undefined) return undefined
    return "apple"
  }
  const docker = async () =>
    (await tryEngine("docker", ["version", "--format", "{{.Server.Version}}"])) === undefined
      ? undefined
      : "docker"
  if (wanted === "apple") return await apple()
  if (wanted === "docker") return await docker()
  return (await apple()) ?? (await docker())
}

const WORKTREE_LABEL = "dev.codevisor.worktree"

/// Removes leftover dev containers for THIS worktree only — a crashed rig
/// must never leave servers running, and other worktrees' containers are
/// never touched.
export async function sweepStaleContainers(engine, worktreeHash) {
  const raw = await tryEngine(engine === "apple" ? "container" : "docker", [
    "list",
    "--all",
    "--format",
    "json"
  ])
  if (raw === undefined) return
  let entries = []
  try {
    const parsed = JSON.parse(raw)
    entries = Array.isArray(parsed) ? parsed : [parsed]
  } catch {
    entries = raw
      .split("\n")
      .filter((line) => line.trim().length > 0)
      .map((line) => JSON.parse(line))
  }
  for (const entry of entries) {
    const labels = entry.configuration?.labels ?? entry.Labels ?? {}
    const label = typeof labels === "string" ? labels : labels[WORKTREE_LABEL]
    const matches =
      typeof label === "string"
        ? label.includes(worktreeHash)
        : labels[WORKTREE_LABEL] === worktreeHash
    if (!matches) continue
    const id = entry.configuration?.id ?? entry.ID ?? entry.Names
    if (typeof id !== "string" || id.length === 0) continue
    await tryEngine(engine === "apple" ? "container" : "docker", ["rm", "--force", id])
  }
}

/// Starts one dev remote server as a Linux container. The container runs
/// the SAME `node dist/main.js serve …` command as the same-host mode, via
/// the bootstrap in scripts/dev-container-entry.sh. All repo-specific
/// state (workspace copy, Linux node_modules, server data) bind-mounts
/// from the worktree's tmp/, so deleting the worktree removes every trace.
export async function startDevContainer(engine, options) {
  const {
    name,
    worktreeHash,
    appRoot,
    stateRoot,
    dataDirectory,
    entryScript,
    port,
    env,
    serveArguments
  } = options
  const binary = engine === "apple" ? "container" : "docker"
  await tryEngine(binary, ["rm", "--force", name])
  const args = [
    "run",
    "--detach",
    "--name",
    name,
    "--label",
    `${WORKTREE_LABEL}=${worktreeHash}`,
    "--volume",
    `${appRoot}:/codevisor`,
    "--volume",
    `${stateRoot}:/codevisor-state`,
    "--volume",
    `${dataDirectory}:/codevisor-data`,
    "--volume",
    `${entryScript}:/entry.sh`,
    "--publish",
    `127.0.0.1:${port}:${port}`
  ]
  for (const [key, value] of Object.entries(env)) {
    if (typeof value === "string") args.push("--env", `${key}=${value}`)
  }
  args.push(DEV_CONTAINER_IMAGE, "sh", "/entry.sh", ...serveArguments)
  await execEngine(binary, args)
  return {
    name,
    stop: async () => {
      await tryEngine(binary, ["rm", "--force", name])
    }
  }
}

export const DEV_CONTAINER_IMAGE = "node:22-bookworm"

export async function ensureDevContainerImage(engine) {
  const binary = engine === "apple" ? "container" : "docker"
  const listed = await tryEngine(
    binary,
    engine === "apple"
      ? ["image", "list", "--format", "json"]
      : ["image", "inspect", DEV_CONTAINER_IMAGE]
  )
  if (
    (listed !== undefined && listed.includes('node:22-bookworm"')) ||
    listed.includes("22-bookworm ")
  )
    return
  console.log(`Pulling ${DEV_CONTAINER_IMAGE} (one-time, shared across worktrees)…`)
  await execEngine(binary, ["image", "pull", DEV_CONTAINER_IMAGE])
}

/// The address containers use to reach services on the host (the dev
/// cloud hub). Docker resolves a magic hostname; Apple containers reach
/// the host at the default network's vmnet gateway, read from the host
/// side so containers need no discovery tooling.
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

/// One-time per-rig-start container preparation: assemble the Linux
/// workspace copy, make sure the stock image exists, sweep this worktree's
/// stale containers, and resolve the host address containers use to reach
/// the dev cloud hub.
export async function prepareDevContainers({ repoRoot, containerRoot, engine, worktreeHash }) {
  await mkdir(join(containerRoot, "state"), { recursive: true })
  const { appRoot } = await syncLinuxWorkspace(repoRoot, containerRoot)
  await ensureDevContainerImage(engine)
  await sweepStaleContainers(engine, worktreeHash)
  return {
    engine,
    worktreeHash,
    appRoot,
    stateRoot: join(containerRoot, "state"),
    entryScript: join(repoRoot, "scripts", "dev-container-entry.sh"),
    hostAddress: await containerHostAddress(engine)
  }
}

/// A ChildProcess-shaped handle for a detached container, so the callers'
/// existing waitForExit / waitForHealth / stop() logic works unchanged on
/// both modes. exitCode flips (and "exit" fires) when the container is
/// gone — it runs with --rm, so stopping and exiting look identical.
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
  environment
}) {
  if (containerContext === undefined) {
    return spawn(
      "node",
      [
        join(repoRoot, "apps/server/dist/main.js"),
        "serve",
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
        "--name",
        serverName,
        "--upgrade-status",
        join(serverRoots.data, "data-upgrade.json")
      ],
      { cwd: repoRoot, env: environment, stdio: "inherit" }
    )
  }
  const { engine, worktreeHash, appRoot, stateRoot, entryScript, hostAddress } = containerContext
  const binary = engine === "apple" ? "container" : "docker"
  const toContainerPath = (hostPath) => hostPath.replace(remoteRootHost, "/codevisor-data")
  const containerName = `codevisor-dev-${serverName.toLowerCase().replace(/[^a-z0-9]+/g, "-")}-${worktreeHash.slice(0, 10)}`
  const rewriteHost = (value) =>
    typeof value === "string"
      ? value.replace("127.0.0.1", hostAddress).replace("localhost", hostAddress)
      : value
  const env = {}
  for (const [key, value] of Object.entries(environment)) {
    if (!key.startsWith("CODEVISOR_") && !key.startsWith("HERDMAN_")) continue
    if (typeof value !== "string") continue
    env[key] = key === "CODEVISOR_DEV_CLOUD_URL" ? rewriteHost(value) : toContainerPath(value)
  }
  await tryEngine(binary, ["rm", "--force", containerName])
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
    "--volume",
    `${remoteRootHost}:/codevisor-data`,
    "--volume",
    `${entryScript}:/entry.sh`,
    "--publish",
    `127.0.0.1:${port}:${port}`
  ]
  for (const [key, value] of Object.entries(env)) args.push("--env", `${key}=${value}`)
  args.push(
    DEV_CONTAINER_IMAGE,
    "sh",
    "/entry.sh",
    "serve",
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
    "--name",
    serverName,
    "--upgrade-status",
    `${toContainerPath(serverRoots.data)}/data-upgrade.json`
  )
  await execEngine(binary, args)
  console.log(`  container ${containerName} (${engine}) → 127.0.0.1:${port}`)
  return makeContainerHandle(binary, containerName)
}
