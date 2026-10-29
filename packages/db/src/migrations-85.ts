import type { Migration } from "./migration-types.js"

const oldestSession = `(
  select sessions.id from sessions
    where sessions.workspace_id = workspaces.id
    order by sessions.origin <> 'codevisor', sessions.created_at, sessions.id
    limit 1
)`

export const migrations85: ReadonlyArray<Migration> = [
  {
    id: 85,
    name: "workspace main session",
    sql: `
      alter table workspaces add column main_session_id text;
      update workspaces set main_session_id = ${oldestSession}
        where exists (select 1 from sessions where sessions.workspace_id = workspaces.id);

      create trigger workspace_main_session_insert after insert on sessions
        when new.workspace_id is not null
        begin
          update workspaces set main_session_id = new.id
            where id = new.workspace_id and main_session_id is null;
        end;

      create trigger workspace_main_session_move after update of workspace_id on sessions
        when new.workspace_id is not old.workspace_id
        begin
          update workspaces set main_session_id = new.id
            where id = new.workspace_id and main_session_id is null;
          update workspaces set main_session_id = ${oldestSession}
            where id = old.workspace_id and main_session_id = old.id;
        end;

      create trigger workspace_main_session_delete after delete on sessions
        when old.workspace_id is not null
        begin
          update workspaces set main_session_id = ${oldestSession}
            where id = old.workspace_id and main_session_id = old.id;
        end;
    `
  }
]
