import type { Migration } from "./migration-types.js"

export const migrations88: ReadonlyArray<Migration> = [
  {
    id: 88,
    name: "archived bots",
    sql: "alter table bots add column archived_at text;"
  }
]
