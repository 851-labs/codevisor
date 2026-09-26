import type { Migration } from "./migration-types.js"

export const migrations54: ReadonlyArray<Migration> = [
  {
    id: 54,
    name: "orchestration links, labels, and prompt origin clients",
    // Agents that orchestrate other agents through the Codevisor gateway need
    // to find their work again after their own context is compacted: a
    // child session records the session that created it, and sessions and
    // workspaces carry free-form key/value labels (JSON objects). A queued
    // prompt records the native window that sent it so the turn it starts can
    // tell the gateway which client originated the request.
    sql: `
      alter table sessions add column parent_session_id text;
      alter table sessions add column labels text;
      alter table workspaces add column labels text;
      alter table prompt_queue_items add column client_id text;
      create index if not exists sessions_parent_session_idx on sessions(parent_session_id);
    `
  }
]
