import type Database from "better-sqlite3"

export const installFleetTurnJournal = (db: Database.Database): void => {
  db.exec(fleetTurnEndedTriggerSql)
}

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
      (session_id, revision, stop_reason, ended_at, transcript_boundary)
    values (
      new.session_id,
      new.revision,
      json_extract(new.payload, '$.stopReason'),
      new.created_at,
      (select max(position) from chat_items where session_id = new.session_id)
    );
  end;`
