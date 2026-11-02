import type { Migration } from "./migration-types.js"

export const migrations89: ReadonlyArray<Migration> = [
  {
    id: 89,
    name: "steered prompt queue items",
    sql: "alter table prompt_queue_items add column steered integer not null default 0;"
  }
]
