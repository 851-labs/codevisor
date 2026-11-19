import type { Migration } from "./migration-types.js"

export const migrations114: ReadonlyArray<Migration> = [
  {
    id: 114,
    name: "an agent can ask to archive itself or its workspace once its turn ends",
    sql: `
      create table deferred_archives (
        session_id text primary key references sessions(id) on delete cascade,
        target text not null check(target in ('chat', 'workspace')),
        workspace_id text,
        scheduled_at text not null,
        due integer not null default 0 check(due in (0, 1)),
        check(target = 'chat' or workspace_id is not null)
      );
      create index deferred_archives_workspace on deferred_archives(workspace_id);
      create index deferred_archives_due on deferred_archives(due) where due = 1;
    `
  }
]
