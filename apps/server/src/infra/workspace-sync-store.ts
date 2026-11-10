import { readJsonStateFile, writeJsonStateFile } from "../json-state-file.js"
import type { WorkspaceSyncRecord } from "./workspace-sync-runner.js"

export interface PendingRemoval {
  readonly machineId: string
  readonly mirrorId: string
}

export interface WorkspaceSyncStore {
  readonly records: () => ReadonlyArray<WorkspaceSyncRecord>
  readonly add: (record: WorkspaceSyncRecord) => void
  readonly remove: (record: WorkspaceSyncRecord) => void
  readonly removals: () => ReadonlyArray<PendingRemoval>
  readonly queueRemoval: (removal: PendingRemoval) => void
  readonly forgetRemoval: (removal: PendingRemoval) => void
}

interface StoredSyncs {
  readonly syncs: ReadonlyArray<WorkspaceSyncRecord>
  readonly removals: ReadonlyArray<PendingRemoval>
}

export const makeWorkspaceSyncStore = (path: string): WorkspaceSyncStore => {
  let stored = readStoredSyncs(path)
  const save = (next: StoredSyncs) => {
    stored = next
    writeJsonStateFile(path, next)
  }
  return {
    records: () => stored.syncs,
    add: (record) => save({ ...stored, syncs: [...stored.syncs, record] }),
    remove: (record) =>
      save({ ...stored, syncs: stored.syncs.filter((other) => !sameMirror(record)(other)) }),
    removals: () => stored.removals,
    queueRemoval: (removal) => {
      if (stored.removals.some(sameMirror(removal))) return
      save({ ...stored, removals: [...stored.removals, removal] })
    },
    forgetRemoval: (removal) => {
      if (!stored.removals.some(sameMirror(removal))) return
      save({ ...stored, removals: stored.removals.filter((other) => !sameMirror(removal)(other)) })
    }
  }
}

const sameMirror =
  (left: PendingRemoval) =>
  (right: PendingRemoval): boolean =>
    left.mirrorId === right.mirrorId

const readStoredSyncs = (path: string): StoredSyncs => {
  const raw = readJsonStateFile(path)
  if (!isRecord(raw)) return { syncs: [], removals: [] }
  return {
    syncs: arrayOf(raw.syncs).filter(isSyncRecord),
    removals: arrayOf(raw.removals).filter(isRemoval)
  }
}

const isRecord = (value: unknown): value is Record<string, unknown> =>
  typeof value === "object" && value !== null && !Array.isArray(value)

const arrayOf = (value: unknown): ReadonlyArray<unknown> => (Array.isArray(value) ? value : [])

const hasStrings = (value: unknown, keys: ReadonlyArray<string>): boolean =>
  isRecord(value) && keys.every((key) => typeof value[key] === "string")

const isSyncRecord = (value: unknown): value is WorkspaceSyncRecord =>
  hasStrings(value, [
    "workspaceId",
    "workspaceName",
    "root",
    "machineId",
    "machineName",
    "mirrorId"
  ])

const isRemoval = (value: unknown): value is PendingRemoval =>
  hasStrings(value, ["machineId", "mirrorId"])
