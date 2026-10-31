import type { Migration } from "./migration-types.js"

export const migrations87: ReadonlyArray<Migration> = [
  {
    id: 87,
    name: "bot display modes",
    sql: `
      alter table bots add column mode text not null default 'transcript';
      update bots set mode = 'conversation' where conversational = 1;
    `
  }
]
