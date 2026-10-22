import type { Migration } from "./migration-types.js"

export const migrations73: ReadonlyArray<Migration> = [
  {
    id: 73,
    name: "remove queued harness updates",
    sql: `drop table if exists harness_pending_updates;`
  }
]
