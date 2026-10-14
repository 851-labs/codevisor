import type { Migration } from "./migration-types.js"

export const migrations58: ReadonlyArray<Migration> = [
  {
    id: 58,
    name: "drop harness-folder skill sync",
    sql: `
      delete from sync_entries
      where namespace in ('skills', 'local.skills-applied', 'skill-readiness');
    `
  }
]
