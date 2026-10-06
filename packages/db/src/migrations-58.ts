import type { Migration } from "./migration-types.js"

export const migrations58: ReadonlyArray<Migration> = [
  {
    id: 58,
    name: "drop harness-folder skill sync",
    // Skills moved from ~/.agents/skills into Codevisor's own store and now
    // replicate under "codevisor-skills". The old replica and its readiness
    // entries are dropped locally rather than tombstoned: a tombstone would
    // gossip to machines still on an older build and delete the user's real
    // skill folders there.
    sql: `
      delete from sync_entries
      where namespace in ('skills', 'local.skills-applied', 'skill-readiness');
    `
  }
]
