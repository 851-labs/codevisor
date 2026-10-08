import type { Migration } from "./migration-types.js"

export const migrations61: ReadonlyArray<Migration> = [
  {
    id: 61,
    name: "replicated navigation records",
    // Account-wide sidebar state (folders, the grouping mode, project order)
    // has no single home machine, so clients replicate every record to every
    // machine they reach. Each row carries the writer's hybrid logical clock;
    // a write lands only when its revision is newer, so every machine and
    // client converges on the same last write. Deletes are tombstones so a
    // late, older copy can never resurrect a removed folder.
    sql: `
      create table nav_folders (
        id text primary key,
        name text not null,
        position text not null,
        collapsed integer not null default 0,
        deleted integer not null default 0,
        revision text not null,
        updated_at text not null
      );
      create table nav_settings (
        key text primary key,
        value text not null,
        revision text not null,
        updated_at text not null
      );
    `
  }
]
