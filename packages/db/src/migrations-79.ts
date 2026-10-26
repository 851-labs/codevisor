import type { Migration } from "./migration-types.js"

export const migrations79: ReadonlyArray<Migration> = [
  {
    id: 79,
    name: "session files",
    sql: `
      create table session_files (
        session_id text not null references sessions(id) on delete cascade,
        file_id text not null references files(id) on delete cascade,
        primary key (session_id, file_id)
      );
      create index session_files_file on session_files(file_id);
    `
  }
]
