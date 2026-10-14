import type { Migration } from "./migration-types.js"

export const migrations51: ReadonlyArray<Migration> = [
  {
    id: 51,
    name: "plan section timestamps on assistant chat items",
    sql: `
      alter table chat_items add column plan_proposed_at text;
      alter table chat_items add column plan_resumed_at text;
    `
  }
]
