import type { Migration } from "./migration-types.js"

export const migrations78: ReadonlyArray<Migration> = [
  {
    id: 78,
    name: "browser favicons",
    sql: `
      create table browser_favicons (
        sha256 text primary key,
        data blob not null,
        used_at integer not null
      );
      create index browser_favicons_used_at on browser_favicons(used_at);
    `
  }
]
