import type { Migration } from "./migration-types.js"

export const migrations75: ReadonlyArray<Migration> = [
  {
    id: 75,
    name: "remote bot parents",
    sql: `alter table workspaces add column remote_bot_parent_session_id text;`
  }
]
