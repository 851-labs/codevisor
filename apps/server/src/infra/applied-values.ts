import type { SyncEntryRecord } from "@codevisor/sync"

export const appliedValuesByKey = (entries: ReadonlyArray<SyncEntryRecord>): Map<string, string> =>
  new Map(
    entries.flatMap((entry): Array<[string, string]> =>
      entry.deleted !== true && typeof entry.value === "string" ? [[entry.key, entry.value]] : []
    )
  )
