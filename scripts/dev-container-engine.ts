// Talking to a container engine: picking one, running its CLI, keeping the
// stock image around, sweeping this worktree's containers, and finding the
// address containers reach the host at. Split out of dev-containers.ts, which
// owns the dev remote lifecycle that runs on top of this.
import { execFile } from "node:child_process"
import type { ExecFileOptionsWithStringEncoding } from "node:child_process"

import type { ContainerEngine } from "./dev-arguments.ts"

/// The engines a dev remote can actually run on. "none" is a request to skip
/// containers entirely, which resolves to `undefined` instead of an engine.
export type DevContainerEngine = Exclude<ContainerEngine, "none">

/// Runs an engine command and resolves with its stdout, or `undefined` when
/// the command failed — the probe shape every optional engine call uses.
export type EngineRunner = (binary: string, args: readonly string[]) => Promise<string | undefined>

export const execEngine = (
  binary: string,
  args: readonly string[],
  // The string-encoding overload is what types `stdout` as a string; the
  // encoding itself stays at execFile's utf8 default.
  options: ExecFileOptionsWithStringEncoding = {}
): Promise<string> =>
  new Promise<string>((resolve, reject) => {
    execFile(binary, args, { maxBuffer: 16 * 1024 * 1024, ...options }, (error, stdout, stderr) => {
      if (error) {
        reject(new Error(`${binary} ${args.join(" ")} failed: ${stderr || error.message}`))
        return
      }
      resolve(stdout)
    })
  })

export const tryEngine = async (
  binary: string,
  args: readonly string[],
  options?: ExecFileOptionsWithStringEncoding
): Promise<string | undefined> => {
  try {
    return await execEngine(binary, args, options)
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
export async function resolveContainerEngine(
  preference?: ContainerEngine | undefined
): Promise<DevContainerEngine | undefined> {
  const wanted = preference ?? process.env.CODEVISOR_DEV_CONTAINER_ENGINE ?? "auto"
  if (wanted === "none") return undefined
  const apple = async (): Promise<DevContainerEngine | undefined> => {
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
  const docker = async (): Promise<DevContainerEngine | undefined> =>
    (await tryEngine("docker", ["version", "--format", "{{.Server.Version}}"])) === undefined
      ? undefined
      : "docker"
  if (wanted === "apple") return await apple()
  if (wanted === "docker") return await docker()
  return (await apple()) ?? (await docker())
}

export const WORKTREE_LABEL = "dev.codevisor.worktree"

/// One container as either engine lists it: Apple nests the fields under
/// `configuration`, Docker flattens them and may serialize labels as a
/// comma-separated string.
interface ContainerListEntry {
  configuration?: { id?: string; labels?: Record<string, string> | string } | undefined
  ID?: string | undefined
  Names?: string | undefined
  Labels?: Record<string, string> | string | undefined
}

/// Removes leftover dev containers for THIS worktree only — a crashed rig
/// must never leave servers running, and other worktrees' containers are
/// never touched.
export async function sweepStaleContainers(
  engine: DevContainerEngine,
  worktreeHash: string,
  runEngine: EngineRunner = (binary, args) => tryEngine(binary, args, { timeout: 5_000 })
): Promise<void> {
  const raw = await runEngine(
    engine === "apple" ? "container" : "docker",
    engine === "apple"
      ? ["list", "--all", "--format", "json"]
      : ["ps", "--all", "--format", "{{json .}}"]
  )
  if (raw === undefined) return
  let entries: ContainerListEntry[] = []
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
    const matches =
      typeof labels === "string"
        ? labels.split(",").some((label) => label === `${WORKTREE_LABEL}=${worktreeHash}`)
        : labels[WORKTREE_LABEL] === worktreeHash
    if (!matches) continue
    const id = entry.configuration?.id ?? entry.ID ?? entry.Names
    if (typeof id !== "string" || id.length === 0) continue
    await runEngine(engine === "apple" ? "container" : "docker", ["rm", "--force", id])
  }
}

export const DEV_CONTAINER_IMAGE = "node:22-bookworm"

export async function ensureDevContainerImage(engine: DevContainerEngine): Promise<void> {
  const binary = engine === "apple" ? "container" : "docker"
  const listed = await tryEngine(
    binary,
    engine === "apple"
      ? ["image", "list", "--format", "json"]
      : ["image", "inspect", DEV_CONTAINER_IMAGE]
  )
  if (
    (listed !== undefined && listed.includes('node:22-bookworm"')) ||
    // Unlike the first operand this one is unguarded, so `listed` is asserted
    // rather than narrowed: the assertion keeps today's behavior exactly.
    listed!.includes("22-bookworm ")
  )
    return
  console.log(`Pulling ${DEV_CONTAINER_IMAGE} (one-time, shared across worktrees)…`)
  await execEngine(binary, ["image", "pull", DEV_CONTAINER_IMAGE])
}

/// `container network inspect default`, reduced to the one field read here.
interface AppleContainerNetwork {
  status?: { ipv4Gateway?: string } | undefined
}

/// The address containers use to reach services on the host (the dev
/// cloud hub). Docker resolves a magic hostname; Apple containers reach
/// the host at the default network's vmnet gateway, read from the host
/// side so containers need no discovery tooling.
export async function containerHostAddress(engine: DevContainerEngine): Promise<string> {
  if (engine === "docker") return "host.docker.internal"
  const raw = await execEngine("container", ["network", "inspect", "default"])
  const parsed: AppleContainerNetwork | AppleContainerNetwork[] = JSON.parse(raw)
  const network = Array.isArray(parsed) ? parsed[0] : parsed
  const gateway = network?.status?.ipv4Gateway
  if (typeof gateway !== "string" || gateway.length === 0) {
    throw new Error("Could not determine the Apple container network gateway")
  }
  return gateway
}
