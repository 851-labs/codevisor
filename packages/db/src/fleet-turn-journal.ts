import type Database from "better-sqlite3"

import { renderableChatItemPredicate } from "./transcript-pages.js"

export const installFleetTurnJournal = (db: Database.Database): void => {
  db.exec(fleetTurnEndedTriggerSql)
}

const finalAssistantTextSql = `coalesce((
    select (
      select substr(text, 1, 24000) from chat_parts
      where item_id = chat_items.id and kind = 'text' order by position limit 1
    )
    from chat_items
    where session_id = new.session_id and role = 'assistant' and ${renderableChatItemPredicate}
    order by position desc limit 1
  ), '')`

const fleetTurnEndedTriggerSql = `
  drop trigger if exists fleet_turn_ended;
  create trigger fleet_turn_ended after insert on session_events
  when new.kind = 'session.updated'
    and json_extract(new.payload, '$.turnState') = 'ended'
    and coalesce(json_extract(new.payload, '$.stopKind'), '') != 'pausedForUpdate'
    and exists (
      select 1 from sessions
      join workspaces on workspaces.id = sessions.workspace_id
      where sessions.id = new.session_id
        and workspaces.remote_bot_parent_session_id = sessions.parent_session_id
    )
  begin
    insert or ignore into fleet_pending_turns
      (session_id, revision, stop_reason, ended_at, final_text)
    values (
      new.session_id,
      new.revision,
      json_extract(new.payload, '$.stopReason'),
      new.created_at,
      ${finalAssistantTextSql}
    );
  end;`
