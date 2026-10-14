import type { Migration } from "./migration-types.js"

export const migrations54: ReadonlyArray<Migration> = [
  {
    id: 54,
    name: "orchestration links, labels, and prompt origin clients",
    sql: `
      alter table sessions add column parent_session_id text;
      alter table sessions add column labels text;
      alter table workspaces add column labels text;
      alter table prompt_queue_items add column client_id text;
      create index if not exists sessions_parent_session_idx on sessions(parent_session_id);
    `
  }
]
