import type { Migration } from "./migration-types.js"

export const migrations96: ReadonlyArray<Migration> = [
  {
    id: 96,
    name: "every bot is a conversation",
    sql: `
      alter table bots drop column conversational;
      alter table bots drop column mode;
    `
  }
]
