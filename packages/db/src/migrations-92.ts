import type { Migration } from "./migration-types.js"

const named = (workspace: string): string =>
  `${workspace}.bot_id is null and ${workspace}.remote_bot_id is null`

const titled = (session: string): string =>
  `${session}.title not in ('', 'New Chat', 'New Session')`

const now = "strftime('%Y-%m-%dT%H:%M:%fZ', 'now')"

const mirrorMainChat = `
  name = main.title, has_custom_name = main.title_is_user_set, updated_at = ${now}
`

const drifted = (workspace: string): string =>
  `(${workspace}.name is not main.title or ${workspace}.has_custom_name is not main.title_is_user_set)`

export const migrations92: ReadonlyArray<Migration> = [
  {
    id: 92,
    name: "workspace name and main chat title are one name",
    sql: `
      drop trigger if exists workspace_name_main_session;
      drop trigger if exists workspace_name_main_session_title;

      update sessions set title = workspaces.name, title_is_user_set = 1
        from workspaces
        where workspaces.main_session_id = sessions.id and ${named("workspaces")}
          and workspaces.has_custom_name = 1
          and (sessions.title is not workspaces.name or sessions.title_is_user_set = 0);

      update sessions set title = workspaces.name
        from workspaces
        where workspaces.main_session_id = sessions.id and ${named("workspaces")}
          and workspaces.has_custom_name = 0 and ${titled("sessions")}
          and sessions.title is not workspaces.name;

      update workspaces set ${mirrorMainChat}
        from sessions as main
        where main.id = workspaces.main_session_id and ${named("workspaces")}
          and ${titled("main")} and ${drifted("workspaces")};

      create trigger workspace_name_follows_main_chat
        after update of title, title_is_user_set on sessions
        when (new.title is not old.title or new.title_is_user_set is not old.title_is_user_set)
          and ${titled("new")}
        begin
          update workspaces set
              name = new.title, has_custom_name = new.title_is_user_set, updated_at = ${now}
            where main_session_id = new.id and ${named("workspaces")}
              and (name is not new.title or has_custom_name is not new.title_is_user_set);
        end;

      create trigger main_chat_follows_workspace_rename
        after update of name, has_custom_name on workspaces
        when new.has_custom_name = 1 and new.main_session_id is not null and ${named("new")}
        begin
          update sessions set title = new.name, title_is_user_set = 1
            where id = new.main_session_id and (title is not new.name or title_is_user_set = 0);
        end;

      create trigger workspace_name_stays_with_main_chat
        after update of name, has_custom_name on workspaces
        when new.has_custom_name = 0 and new.main_session_id is not null and ${named("new")}
        begin
          update workspaces set ${mirrorMainChat}
            from sessions as main
            where workspaces.id = new.id and main.id = new.main_session_id
              and ${titled("main")} and ${drifted("workspaces")};
        end;

      create trigger workspace_name_main_chat_changed
        after update of main_session_id on workspaces
        when new.main_session_id is not null and ${named("new")}
        begin
          update sessions set title = new.name, title_is_user_set = 1
            where id = new.main_session_id and title_is_user_set = 0 and new.has_custom_name = 1;
          update workspaces set ${mirrorMainChat}
            from sessions as main
            where workspaces.id = new.id and main.id = new.main_session_id
              and ${titled("main")} and ${drifted("workspaces")};
        end;
    `
  }
]
