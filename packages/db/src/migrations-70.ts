import type { Migration } from "./migration-types.js"

export const migrations70: ReadonlyArray<Migration> = [
  {
    id: 70,
    name: "session auto resumes",
    sql: `
      create table session_auto_resumes (
        session_id text primary key references sessions(id) on delete cascade,
        harness_id text not null,
        harness_account_id text,
        state text not null,
        resets_at text,
        check_at text not null,
        checks integer not null default 0,
        created_at text not null
      );
      create index session_auto_resumes_check_idx on session_auto_resumes(state, check_at);
    `
  }
]
