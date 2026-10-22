import { readJsonStateFile, removeJsonStateFile, writeJsonStateFile } from "./json-state-file.js"
import { field } from "./unknown-values.js"

export interface RestartSnapshotStore {
  readonly read: () => ReadonlyArray<string> | undefined
  readonly write: (sessionIds: ReadonlyArray<string>) => void
  readonly clear: () => void
}

/* v8 ignore start */
export const makeFileRestartSnapshotStore = (path: string): RestartSnapshotStore => ({
  read: () => {
    const sessions = field(readJsonStateFile(path), "sessions")
    return Array.isArray(sessions)
      ? sessions.filter((id): id is string => typeof id === "string")
      : undefined
  },
  write: (sessionIds) => {
    writeJsonStateFile(path, { sessions: sessionIds, at: new Date().toISOString() })
  },
  clear: () => {
    removeJsonStateFile(path)
  }
})
/* v8 ignore stop */

export const makeMemoryRestartSnapshotStore = (): RestartSnapshotStore => {
  let value: ReadonlyArray<string> | undefined
  return {
    read: () => value,
    write: (sessionIds) => {
      value = [...sessionIds]
    },
    clear: () => {
      value = undefined
    }
  }
}
