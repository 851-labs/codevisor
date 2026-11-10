import { randomUUID } from "node:crypto"
import { rm } from "node:fs/promises"
import { join } from "node:path"

import type { WorkspaceMirrorStatus } from "@codevisor/api"

import { makeWorkspaceMirrorRecords, type PendingRemoval } from "./workspace-mirror-records.js"
import {
  MirrorRunner,
  type MirrorTransport,
  type WorkspaceMirrorRecord
} from "./workspace-mirror-runner.js"

export type { MirrorTransport, WorkspaceMirrorRecord } from "./workspace-mirror-runner.js"

export interface MirrorSource {
  readonly id: string
  readonly name: string
  readonly root: string
}

export interface MirrorTarget {
  readonly id: string
  readonly name: string
}

export interface WaitedMirrorStatus extends WorkspaceMirrorStatus {
  readonly timedOut: boolean
}

export interface WorkspaceMirrors {
  readonly start: (source: MirrorSource, target: MirrorTarget) => Promise<WorkspaceMirrorStatus>
  readonly list: (workspaceId: string) => Promise<ReadonlyArray<WorkspaceMirrorStatus>>
  readonly status: (
    workspaceId: string,
    machineId: string
  ) => Promise<WorkspaceMirrorStatus | undefined>
  readonly wait: (
    workspaceId: string,
    machineId: string,
    timeoutMs: number
  ) => Promise<WaitedMirrorStatus | undefined>
  readonly stop: (workspaceId: string, machineId: string) => Promise<boolean>
  readonly stopAll: (workspaceId: string) => Promise<void>
  readonly forgetMachine: (machineId: string) => Promise<void>
  readonly machines: () => ReadonlyArray<string>
  readonly close: () => void
}

export interface WorkspaceMirrorsOptions {
  readonly directory: string
  readonly transport: MirrorTransport
  readonly intervalMs?: number
  readonly retryMs?: number
  readonly removalRetryMs?: number
  readonly now?: () => Date
}

export const makeWorkspaceMirrors = (options: WorkspaceMirrorsOptions): WorkspaceMirrors => {
  const store = makeWorkspaceMirrorRecords(join(options.directory, "workspace-mirrors.json"))
  const runners = new Map<string, MirrorRunner>()
  const now = options.now ?? (() => new Date())

  const launch = (record: WorkspaceMirrorRecord): MirrorRunner => {
    const runner = new MirrorRunner({
      record,
      repo: { gitDir: snapshotDir(options.directory, record.mirrorId), workTree: record.root },
      transport: options.transport,
      intervalMs: options.intervalMs ?? DEFAULT_INTERVAL_MS,
      retryMs: options.retryMs ?? DEFAULT_RETRY_MS,
      now
    })
    runners.set(syncKey(record.workspaceId, record.machineId), runner)
    runner.start()
    return runner
  }

  const removeMirror = async (removal: PendingRemoval): Promise<void> => {
    try {
      await options.transport.remove(removal.machineId, removal.mirrorId)
      store.forgetRemoval(removal)
    } catch {
      store.queueRemoval(removal)
    }
  }

  const retryRemovals = () => {
    for (const removal of store.removals()) void removeMirror(removal)
  }

  for (const record of store.records()) launch(record)
  retryRemovals()
  const removalTimer = setInterval(retryRemovals, options.removalRetryMs ?? REMOVAL_RETRY_MS)
  removalTimer.unref()

  const retire = async (runner: MirrorRunner): Promise<void> => {
    runners.delete(syncKey(runner.record.workspaceId, runner.record.machineId))
    await runner.stop()
    store.remove(runner.record)
    await rm(snapshotDir(options.directory, runner.record.mirrorId), {
      recursive: true,
      force: true
    })
  }

  const stop = async (workspaceId: string, machineId: string): Promise<boolean> => {
    const runner = runners.get(syncKey(workspaceId, machineId))
    if (runner === undefined) return false
    await retire(runner)
    await removeMirror({ machineId, mirrorId: runner.record.mirrorId })
    return true
  }

  const forgetMachine = async (machineId: string): Promise<void> => {
    const targeting = [...runners.values()].filter(
      (runner) => runner.record.machineId === machineId
    )
    for (const runner of targeting) await retire(runner)
    for (const removal of store.removals()) {
      if (removal.machineId === machineId) store.forgetRemoval(removal)
    }
  }

  return {
    start: async (source, target) => {
      const existing = runners.get(syncKey(source.id, target.id))
      if (existing !== undefined) return existing.status()
      const record = newRecord(source, target)
      store.add(record)
      return launch(record).status()
    },
    list: (workspaceId) =>
      Promise.all(
        [...runners.values()]
          .filter((runner) => runner.record.workspaceId === workspaceId)
          .map((runner) => runner.status())
      ),
    status: async (workspaceId, machineId) =>
      runners.get(syncKey(workspaceId, machineId))?.status(),
    wait: async (workspaceId, machineId, timeoutMs) => {
      const runner = runners.get(syncKey(workspaceId, machineId))
      if (runner === undefined) return undefined
      const timedOut = await passOrTimeout(runner, timeoutMs)
      return { ...(await runner.status()), timedOut }
    },
    stop,
    stopAll: async (workspaceId) => {
      const machines = [...runners.values()]
        .filter((runner) => runner.record.workspaceId === workspaceId)
        .map((runner) => runner.record.machineId)
      for (const machineId of machines) await stop(workspaceId, machineId)
    },
    forgetMachine,
    machines: () => [
      ...new Set([
        ...[...runners.values()].map((runner) => runner.record.machineId),
        ...store.removals().map((removal) => removal.machineId)
      ])
    ],
    close: () => {
      clearInterval(removalTimer)
      for (const runner of runners.values()) void runner.stop()
    }
  }
}

const DEFAULT_INTERVAL_MS = 1_000
const DEFAULT_RETRY_MS = 5_000
const REMOVAL_RETRY_MS = 30_000

const syncKey = (workspaceId: string, machineId: string): string =>
  `${workspaceId.toLowerCase()}|${machineId}`

const snapshotDir = (directory: string, mirrorId: string): string =>
  join(directory, "workspace-mirrors", mirrorId)

const newRecord = (source: MirrorSource, target: MirrorTarget): WorkspaceMirrorRecord => ({
  workspaceId: source.id,
  workspaceName: source.name,
  root: source.root,
  machineId: target.id,
  machineName: target.name,
  mirrorId: randomUUID()
})

const passOrTimeout = async (runner: MirrorRunner, timeoutMs: number): Promise<boolean> => {
  let timer: ReturnType<typeof setTimeout> | undefined
  const timeout = new Promise<boolean>((resolve) => {
    timer = setTimeout(() => resolve(true), timeoutMs)
  })
  const timedOut = await Promise.race([runner.nextPass().then(() => false), timeout])
  clearTimeout(timer)
  return timedOut
}
