import type { Migration } from "./migration-types.js"

const namedByChat = (workspace: string): string =>
  `${workspace}.has_custom_name = 0 and ${workspace}.bot_id is null and ${workspace}.remote_bot_id is null`

const titled = (session: string): string =>
  `${session}.title not in ('', 'New Chat', 'New Session')`

const now = "strftime('%Y-%m-%dT%H:%M:%fZ', 'now')"

export const migrations86: ReadonlyArray<Migration> = [
  {
    id: 86,
    name: "workspace named after main session",
    sql: `
      create index workspaces_main_session_id on workspaces(main_session_id);

      update workspaces set name = main.title, updated_at = ${now}
        from sessions as main
        where main.id = workspaces.main_session_id and ${titled("main")}
          and ${namedByChat("workspaces")} and workspaces.name is not main.title;

      create trigger workspace_name_main_session after update of main_session_id on workspaces
        when new.main_session_id is not null and ${namedByChat("new")}
        begin
          update workspaces set
              name = (select title from sessions where id = new.main_session_id),
              updated_at = ${now}
            where id = new.id and exists (
              select 1 from sessions
                where id = new.main_session_id and ${titled("sessions")} and title is not new.name
            );
        end;

      create trigger workspace_name_main_session_title after update of title on sessions
        when new.title is not old.title and ${titled("new")}
        begin
          update workspaces set name = new.title, updated_at = ${now}
            where main_session_id = new.id and ${namedByChat("workspaces")} and name is not new.title;
        end;
    `
  }
]
