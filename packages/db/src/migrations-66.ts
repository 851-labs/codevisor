import type { Migration } from "./migration-types.js"

export const migrations66: ReadonlyArray<Migration> = [
  {
    id: 66,
    name: "bot workspaces",
    sql: `
      alter table workspaces add column bot_id text references bots(id) on delete set null;
      create index workspaces_bot_idx on workspaces(bot_id);
    `
  }
]
