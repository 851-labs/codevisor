import type { Migration } from "./migration-types.js"

export const migrations77: ReadonlyArray<Migration> = [
  {
    id: 77,
    name: "fleet pending turns",
    sql: `
      create table fleet_pending_turns (
        session_id text not null,
        revision integer not null,
        stop_reason text,
        primary key (session_id, revision)
      );
    `
  }
]
