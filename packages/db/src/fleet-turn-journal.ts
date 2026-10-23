import type Database from "better-sqlite3"

export const installFleetTurnJournal = (db: Database.Database): void => {
  db.exec(fleetTurnEndedTriggerSql)
}

const fleetTurnEndedTriggerSql = `
  create trigger if not exists fleet_turn_ended after insert on session_events
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
    insert or ignore into fleet_pending_turns (session_id, revision, stop_reason)
    values (new.session_id, new.revision, json_extract(new.payload, '$.stopReason'));
  end;`
