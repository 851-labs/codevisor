import type { ExecTasks } from "./exec-tasks.js"
import type { MirrorStore } from "./mirror-store.js"
import type { RemoteExecTasks } from "./remote-exec-tasks.js"
import type { WorkspaceMirrors } from "./workspace-mirrors.js"

export interface OrphanSweepOptions {
  readonly isGone: (machineId: string) => boolean
  readonly mirrors: MirrorStore
  readonly execTasks: ExecTasks
  readonly remoteExecTasks: RemoteExecTasks
  readonly workspaceMirrors: WorkspaceMirrors
  readonly intervalMs?: number
}

export interface OrphanSweep {
  readonly sweep: () => Promise<void>
  readonly close: () => void
}

export const ORPHAN_SWEEP_INTERVAL_MS = 60_000

export const makeOrphanSweep = (options: OrphanSweepOptions): OrphanSweep => {
  let running: Promise<void> | undefined
  const sweep = (): Promise<void> => {
    running ??= sweepOnce(options).finally(() => {
      running = undefined
    })
    return running
  }
  const timer = setInterval(() => {
    void sweep().catch(() => undefined)
  }, options.intervalMs ?? ORPHAN_SWEEP_INTERVAL_MS)
  timer.unref()
  return { sweep, close: () => clearInterval(timer) }
}

const sweepOnce = async (options: OrphanSweepOptions): Promise<void> => {
  const { isGone } = options
  for (const mirror of await options.mirrors.owned()) {
    if (isGone(mirror.owner)) await options.mirrors.remove(mirror.mirrorId)
  }
  for (const task of options.execTasks.owned()) {
    if (isGone(task.owner)) await options.execTasks.stop(task.taskId)
  }
  for (const task of options.remoteExecTasks.list()) {
    if (isGone(task.machine.machineId)) options.remoteExecTasks.forget(task.taskId)
  }
  for (const machineId of options.workspaceMirrors.machines()) {
    if (isGone(machineId)) await options.workspaceMirrors.forgetMachine(machineId)
  }
}
