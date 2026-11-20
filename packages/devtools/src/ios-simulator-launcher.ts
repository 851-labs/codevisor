import { mkdir, open, stat } from "node:fs/promises"
import { dirname, join } from "node:path"
import { setTimeout as delay } from "node:timers/promises"

import {
  simulatorMatchesRequest,
  simulatorMismatch,
  simulatorReadyBlock,
  simulatorStaysUp
} from "./ios-simulator-ready.ts"
import {
  type IdentityLookup,
  isSameProcess,
  listDevices,
  type OwnerIdentity,
  readJSON,
  reapOrphanedSimulators,
  requireIOSSimulator,
  type SimulatorManifest,
  type SimulatorOptions,
  simulatorClaimPath,
  simulatorLogPath,
  simulatorManifestPath,
  simulatorOwnerAlive
} from "./ios-simulator-state.ts"
import { type DetachedTask, startDetachedTask } from "./owned-task.ts"

export interface SimulatorLauncherDependencies {
  readonly identity: IdentityLookup
  readonly startOwner: (logPath: string) => DetachedTask
  readonly signal?: (pid: number, signal: NodeJS.Signals) => void
  readonly simctl?: (args: ReadonlyArray<string>) => Promise<string>
  readonly write?: (text: string) => void
  readonly pollMilliseconds?: number
  readonly stopTimeoutMilliseconds?: number
}

export type SimulatorOutcome =
  | { readonly kind: "started" | "reused"; readonly manifest: SimulatorManifest }
  | { readonly kind: "failed"; readonly reason: string }

interface LogFollower {
  readonly copy: () => Promise<void>
}

const defaultPollMilliseconds = 250
const defaultStopTimeoutMilliseconds = 180_000

export function simulatorLauncher(
  repoRoot: string,
  identity: IdentityLookup,
  args: ReadonlyArray<string>
): SimulatorLauncherDependencies {
  const ownerScript = join(repoRoot, "scripts", "ios-simulator-owner.mjs")
  return { identity, startOwner: (logPath) => startDetachedTask(ownerScript, args, logPath) }
}

export async function startIOSSimulator(
  repoRoot: string,
  options: SimulatorOptions,
  dependencies: SimulatorLauncherDependencies
): Promise<number> {
  const outcome = await ensureIOSSimulator(repoRoot, options, dependencies)
  if (outcome.kind === "failed") return failure(dependencies, outcome.reason)

  if (outcome.kind === "reused")
    print(
      dependencies,
      `This worktree's simulator is already running.\n${simulatorReadyBlock(outcome.manifest)}`
    )
  print(dependencies, `Start the apps with bun run dev:ios. ${simulatorStaysUp}`)
  return 0
}

export async function ensureIOSSimulator(
  repoRoot: string,
  options: SimulatorOptions,
  dependencies: SimulatorLauncherDependencies
): Promise<SimulatorOutcome> {
  const owner = await claimedOwner(repoRoot, dependencies.identity)
  if (owner !== undefined) return await runningSimulator(repoRoot, owner, options, dependencies)

  return await launchOwner(repoRoot, options, dependencies)
}

export async function stopIOSSimulator(
  repoRoot: string,
  dependencies: SimulatorLauncherDependencies
): Promise<number> {
  const manifest = asManifest(await readJSON(simulatorManifestPath(repoRoot)))
  const owner = await claimedOwner(repoRoot, dependencies.identity)
  if (owner === undefined) await reapOrphanedSimulators(dependencies)
  else if (!(await stopOwner(owner, dependencies)))
    return failure(dependencies, stillStopping(repoRoot))

  if (manifest === undefined) {
    print(dependencies, "No simulator is running for this worktree.")
    return 0
  }
  if (await deviceExists(manifest.udid, dependencies))
    return failure(
      dependencies,
      `Simulator ${manifest.udid} was not deleted. Its owner's log is ${simulatorLogPath(repoRoot)}.`
    )

  print(dependencies, `Deleted this worktree's simulator ${manifest.name} (${manifest.udid}).`)
  return 0
}

async function launchOwner(
  repoRoot: string,
  options: SimulatorOptions,
  dependencies: SimulatorLauncherDependencies
): Promise<SimulatorOutcome> {
  const logPath = simulatorLogPath(repoRoot)
  await mkdir(dirname(logPath), { recursive: true })
  const follower = followLog(logPath, await sizeOf(logPath), dependencies)
  const task = dependencies.startOwner(logPath)
  let running = true
  void task.exited.then(() => {
    running = false
  })
  const manifest = await waitForReady(repoRoot, () => running, follower, dependencies)
  task.release()
  if (manifest !== undefined) return { kind: "started", manifest }

  const winner = await claimedOwner(repoRoot, dependencies.identity)
  if (winner !== undefined) return await runningSimulator(repoRoot, winner, options, dependencies)

  return failed(`The simulator did not start. Its owner's log is ${logPath}.`)
}

async function runningSimulator(
  repoRoot: string,
  owner: OwnerIdentity,
  options: SimulatorOptions,
  dependencies: SimulatorLauncherDependencies
): Promise<SimulatorOutcome> {
  if ((await readyManifest(repoRoot, dependencies.identity)) === undefined) {
    print(dependencies, "This worktree's simulator is still starting; waiting until it is ready.")
    const ownerRunning = async () => isSameProcess(owner, await dependencies.identity(owner.pid))
    const ready = await waitForReady(repoRoot, ownerRunning, { copy: async () => {} }, dependencies)
    if (ready === undefined)
      return failed(
        `This worktree's simulator stopped before it was ready. Its owner's log is ${simulatorLogPath(repoRoot)}.`
      )
  }

  const manifest = await usableSimulator(repoRoot, dependencies)
  if (manifest === undefined)
    return failed(
      "This worktree's simulator owner is running, but its device is not booted. Remove it with bun run ios-simulator --stop, then start it again."
    )
  if (!simulatorMatchesRequest(manifest, options)) return failed(simulatorMismatch(manifest))

  return { kind: "reused", manifest }
}

async function waitForReady(
  repoRoot: string,
  ownerRunning: () => boolean | Promise<boolean>,
  follower: LogFollower,
  dependencies: SimulatorLauncherDependencies
): Promise<SimulatorManifest | undefined> {
  for (;;) {
    const running = await ownerRunning()
    await follower.copy()
    const manifest = await readyManifest(repoRoot, dependencies.identity)
    if (manifest !== undefined || !running) return manifest

    await delay(dependencies.pollMilliseconds ?? defaultPollMilliseconds)
  }
}

async function stopOwner(
  owner: OwnerIdentity,
  dependencies: SimulatorLauncherDependencies
): Promise<boolean> {
  ;(dependencies.signal ?? sendSignal)(owner.pid, "SIGTERM")
  const deadline =
    Date.now() + (dependencies.stopTimeoutMilliseconds ?? defaultStopTimeoutMilliseconds)
  while (isSameProcess(owner, await dependencies.identity(owner.pid))) {
    if (Date.now() > deadline) return false

    await delay(dependencies.pollMilliseconds ?? defaultPollMilliseconds)
  }
  return true
}

async function claimedOwner(
  repoRoot: string,
  identity: IdentityLookup
): Promise<OwnerIdentity | undefined> {
  const claim = asClaim(await readJSON(simulatorClaimPath(repoRoot)))
  if (claim === undefined) return undefined

  const owner = {
    pid: claim.pid,
    ...(claim.startedAt === undefined ? {} : { startedAt: claim.startedAt })
  }
  return isSameProcess(owner, await identity(claim.pid)) ? owner : undefined
}

async function readyManifest(
  repoRoot: string,
  identity: IdentityLookup
): Promise<SimulatorManifest | undefined> {
  const manifest = asManifest(await readJSON(simulatorManifestPath(repoRoot)))
  if (manifest?.repoRoot !== repoRoot || manifest.ready !== true) return undefined

  return (await simulatorOwnerAlive(manifest, identity)) ? manifest : undefined
}

async function usableSimulator(
  repoRoot: string,
  dependencies: SimulatorLauncherDependencies
): Promise<SimulatorManifest | undefined> {
  try {
    return await requireIOSSimulator(repoRoot, dependencies)
  } catch {
    return undefined
  }
}

async function deviceExists(
  udid: string,
  dependencies: SimulatorLauncherDependencies
): Promise<boolean> {
  return (await listDevices(dependencies)).some((device) => device.udid === udid)
}

function followLog(
  path: string,
  offset: number,
  dependencies: SimulatorLauncherDependencies
): LogFollower {
  let position = offset
  return {
    copy: async () => {
      const text = await readFrom(path, position)
      position += Buffer.byteLength(text)
      if (text.length > 0) (dependencies.write ?? writeToStdout)(text)
    }
  }
}

async function readFrom(path: string, position: number): Promise<string> {
  const size = await sizeOf(path)
  if (size <= position) return ""

  const handle = await open(path, "r")
  try {
    const buffer = Buffer.alloc(size - position)
    const { bytesRead } = await handle.read(buffer, 0, buffer.length, position)
    return buffer.subarray(0, bytesRead).toString("utf8")
  } finally {
    await handle.close()
  }
}

async function sizeOf(path: string): Promise<number> {
  try {
    return (await stat(path)).size
  } catch {
    return 0
  }
}

function stillStopping(repoRoot: string): string {
  return `This worktree's simulator owner did not stop in time. Its log is ${simulatorLogPath(repoRoot)}.`
}

function asClaim(value: unknown): { pid: number; startedAt?: string } | undefined {
  if (value === null || typeof value !== "object" || !("pid" in value)) return undefined
  if (typeof value.pid !== "number" || !Number.isSafeInteger(value.pid)) return undefined

  const startedAt =
    "startedAt" in value && typeof value.startedAt === "string" ? value.startedAt : undefined
  return { pid: value.pid, ...(startedAt === undefined ? {} : { startedAt }) }
}

function asManifest(value: unknown): SimulatorManifest | undefined {
  return isManifest(value) ? value : undefined
}

function isManifest(value: unknown): value is SimulatorManifest {
  return (
    value !== null && typeof value === "object" && "udid" in value && typeof value.udid === "string"
  )
}

function print(dependencies: SimulatorLauncherDependencies, line: string): void {
  ;(dependencies.write ?? writeToStdout)(`${line}\n`)
}

function failed(reason: string): SimulatorOutcome {
  return { kind: "failed", reason }
}

function failure(dependencies: SimulatorLauncherDependencies, line: string): number {
  ;(dependencies.write ?? writeToStderr)(`${line}\n`)
  return 1
}

function sendSignal(pid: number, signal: NodeJS.Signals): void {
  process.kill(pid, signal)
}

function writeToStdout(text: string): void {
  process.stdout.write(text)
}

function writeToStderr(text: string): void {
  process.stderr.write(text)
}
