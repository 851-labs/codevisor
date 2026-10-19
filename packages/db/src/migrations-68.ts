import type { Migration } from "./migration-types.js"

export const migrations68: ReadonlyArray<Migration> = [
  {
    id: 68,
    name: "conversational bots",
    sql: `alter table bots add column conversational integer not null default 0;`
  }
]
