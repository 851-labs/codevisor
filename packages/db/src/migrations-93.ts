import type { Migration } from "./migration-types.js"

export const migrations93: ReadonlyArray<Migration> = [
  {
    id: 93,
    name: "who created each chat, an agent or the user",
    sql: `alter table sessions add column created_by text;`
  }
]
