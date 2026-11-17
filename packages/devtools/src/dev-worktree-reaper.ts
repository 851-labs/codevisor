import { spawn } from "node:child_process"
import { sep } from "node:path"

import { purgeDevelopmentAppState } from "./dev-app-state.ts"
import { sweepStaleContainers } from "./dev-containers.ts"
import {
  type ClaimedInstance,
  claimedInstances,
  devInstancesRoot,
  instanceHash,
  worktreeIsGone
} from "./dev-instance-roots.ts"

export interface RunningProcess {
  readonly pid: number
  readonly command: string
}

export interface WorktreeReaper {
  readonly removeContainers: (instanceHash: string) => Promise<unknown>
  readonly readProcessTable: () => Promise<ReadonlyArray<RunningProcess>>
  readonly stopProcesses: (
    processes: ReadonlyArray<RunningProcess>,
    options: { graceMs: number }
  ) => Promise<unknown>
  readonly purgeAppState: (instanceHash: string) => Promise<unknown>
  readonly removeInstanceRoot: (path: string) => Promise<unknown> | void
}

export type ProcessControl = Pick<WorktreeReaper, "readProcessTable" | "stopProcesses">

const processGraceMilliseconds = 2_000

export function nativeWorktreeReaper(processes: ProcessControl): WorktreeReaper {
  return {
    ...processes,
    removeContainers: (hash) =>
      Promise.all([sweepStaleContainers("apple", hash), sweepStaleContainers("docker", hash)]),
    purgeAppState: purgeDevelopmentAppState,
    removeInstanceRoot: removeInBackground
  }
}

export async function reapDeletedWorktrees(
  reaper: WorktreeReaper,
  instancesRoot = devInstancesRoot()
): Promise<ReadonlyArray<string>> {
  const reaped: Array<string> = []
  const failures: Array<unknown> = []
  for (const instance of await claimedInstances(instancesRoot)) {
    if (!(await worktreeIsGone(instance.repoRoot))) continue

    try {
      await reapWorktree(instance, reaper)
      reaped.push(instance.repoRoot)
    } catch (error) {
      failures.push(error)
    }
  }
  if (failures.length > 0) throw new AggregateError(failures, failures.map(messageOf).join("; "))
  return reaped
}

export async function reapOwnWorktreeIfGone(
  repoRoot: string,
  reaper: WorktreeReaper,
  instancesRoot = devInstancesRoot()
): Promise<boolean> {
  if (!(await worktreeIsGone(repoRoot))) return false

  const hash = instanceHash(repoRoot)
  const claimed = (await claimedInstances(instancesRoot)).find((instance) => instance.hash === hash)
  if (claimed === undefined) await reapResources({ hash, repoRoot }, reaper)
  else await reapWorktree(claimed, reaper)
  return true
}

async function reapWorktree(instance: ClaimedInstance, reaper: WorktreeReaper): Promise<void> {
  await reapResources(instance, reaper)
  await reaper.removeInstanceRoot(instance.root)
}

async function reapResources(
  instance: Pick<ClaimedInstance, "hash" | "repoRoot">,
  reaper: WorktreeReaper
): Promise<void> {
  const steps = await Promise.allSettled([
    reaper.removeContainers(instance.hash),
    stopProcessesFrom(instance.repoRoot, reaper),
    reaper.purgeAppState(instance.hash)
  ])
  const failures = steps.flatMap((step) => (step.status === "rejected" ? [step.reason] : []))
  if (failures.length > 0)
    throw new AggregateError(failures, `Could not clean up after ${instance.repoRoot}`)
}

async function stopProcessesFrom(repoRoot: string, reaper: WorktreeReaper): Promise<void> {
  const prefix = `${repoRoot}${sep}`
  const running = (await reaper.readProcessTable()).filter((entry) =>
    entry.command.startsWith(prefix)
  )
  if (running.length > 0) await reaper.stopProcesses(running, { graceMs: processGraceMilliseconds })
}

function messageOf(error: unknown): string {
  return error instanceof Error ? error.message : String(error)
}

function removeInBackground(path: string): void {
  spawn("/bin/rm", ["-rf", "--", path], { detached: true, stdio: "ignore" }).unref()
}
