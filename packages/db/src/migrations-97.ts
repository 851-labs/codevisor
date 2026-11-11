import { parseRemoteSessionKey } from "@codevisor/api"
import type Database from "better-sqlite3"

import type { Migration } from "./migration-types.js"
import { nullable, rowReader, text } from "./row-reader.js"

const titled = (session: string): string =>
  `${session}.title not in ('', 'New Chat', 'New Session')`

const now = "strftime('%Y-%m-%dT%H:%M:%fZ', 'now')"

const mirrorMainChat = `
  name = main.title, has_custom_name = main.title_is_user_set, updated_at = ${now}
`

const drifted = (workspace: string): string =>
  `(${workspace}.name is not main.title or ${workspace}.has_custom_name is not main.title_is_user_set)`

const addReferenceColumnsSql = `
  alter table sessions add column created_by_agent_id text;
  alter table sessions add column created_by_agent_machine_id text;
  alter table sessions add column forked_from_agent_id text;
  alter table sessions add column forked_from_agent_machine_id text;
`

const dropOldReferencesSql = `
  drop index if exists sessions_parent_session_idx;
  alter table sessions drop column parent_session_id;
  create index sessions_created_by_agent_idx on sessions(created_by_agent_id);

  drop trigger if exists workspace_name_follows_main_chat;
  drop trigger if exists main_chat_follows_workspace_rename;
  drop trigger if exists workspace_name_stays_with_main_chat;
  drop trigger if exists workspace_name_main_chat_changed;
  drop index if exists workspaces_bot_idx;
  alter table workspaces drop column bot_id;
  alter table workspaces drop column remote_bot_id;
  alter table workspaces drop column remote_bot_machine_id;
  alter table workspaces drop column remote_bot_parent_session_id;
  drop table if exists fleet_pending_turns;

  create trigger workspace_name_follows_main_chat
    after update of title, title_is_user_set on sessions
    when (new.title is not old.title or new.title_is_user_set is not old.title_is_user_set)
      and ${titled("new")}
    begin
      update workspaces set
          name = new.title, has_custom_name = new.title_is_user_set, updated_at = ${now}
        where main_session_id = new.id
          and (name is not new.title or has_custom_name is not new.title_is_user_set);
    end;

  create trigger main_chat_follows_workspace_rename
    after update of name, has_custom_name on workspaces
    when new.has_custom_name = 1 and new.main_session_id is not null
    begin
      update sessions set title = new.name, title_is_user_set = 1
        where id = new.main_session_id and (title is not new.name or title_is_user_set = 0);
    end;

  create trigger workspace_name_stays_with_main_chat
    after update of name, has_custom_name on workspaces
    when new.has_custom_name = 0 and new.main_session_id is not null
    begin
      update workspaces set ${mirrorMainChat}
        from sessions as main
        where workspaces.id = new.id and main.id = new.main_session_id
          and ${titled("main")} and ${drifted("workspaces")};
    end;

  create trigger workspace_name_main_chat_changed
    after update of main_session_id on workspaces
    when new.main_session_id is not null
    begin
      update sessions set title = new.name, title_is_user_set = 1
        where id = new.main_session_id and title_is_user_set = 0 and new.has_custom_name = 1;
      update workspaces set ${mirrorMainChat}
        from sessions as main
        where workspaces.id = new.id and main.id = new.main_session_id
          and ${titled("main")} and ${drifted("workspaces")};
    end;
`

const linkedSessionsSql = `select id, server_id, parent_session_id, created_by from sessions
  where parent_session_id is not null`

const setCreatedBySql = `update sessions
  set created_by_agent_id = ?, created_by_agent_machine_id = ? where id = ?`

const setForkedFromSql = `update sessions
  set forked_from_agent_id = ?, forked_from_agent_machine_id = ? where id = ?`

const linkedSessionRows = rowReader({
  id: text,
  server_id: text,
  parent_session_id: text,
  created_by: nullable(text)
})

const splitParentReferences = (sqlite: Database.Database): void => {
  const setCreatedBy = sqlite.prepare(setCreatedBySql)
  const setForkedFrom = sqlite.prepare(setForkedFromSql)
  for (const row of linkedSessionRows.all(sqlite.prepare(linkedSessionsSql).all())) {
    const remote = parseRemoteSessionKey(row.parent_session_id)
    const agentId = remote?.sessionId ?? row.parent_session_id
    const machineId = remote?.machineId ?? row.server_id
    const update = row.created_by === "agent" ? setCreatedBy : setForkedFrom
    update.run(agentId, machineId, row.id)
  }
}

export const migrations97: ReadonlyArray<Migration> = [
  {
    id: 97,
    name: "agent references name who created or forked a chat, and on which machine",
    sql: addReferenceColumnsSql,
    run: (sqlite) => {
      splitParentReferences(sqlite)
      sqlite.exec(dropOldReferencesSql)
    }
  }
]
