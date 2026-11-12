import type { Migration } from "./migration-types.js"

export const migrations100: ReadonlyArray<Migration> = [
  {
    id: 100,
    name: "chats own their archived state, apart from the workspace that shows them",
    sql: `
      drop trigger if exists navigation_sessions_update;
      alter table sessions add column is_archived integer not null default 0;
      alter table sessions add column archived_at text;
      update sessions set is_archived = 1, archived_at = (
          select archived_at from workspaces where workspaces.id = sessions.workspace_id
        )
        where exists (
          select 1 from workspaces
            where workspaces.id = sessions.workspace_id and workspaces.is_archived = 1
        );
      create index sessions_archived_idx on sessions(is_archived);
    `
  }
]
