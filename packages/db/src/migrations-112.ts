import type { Migration } from "./migration-types.js"

export const migrations112: ReadonlyArray<Migration> = [
  {
    id: 112,
    name: "bots say what they do, and each machine keeps the list of bots on the others",
    sql: `
      alter table bots add column about text;
      create table fleet_bots (
        machine_id text not null,
        bot_id text not null,
        machine_name text not null,
        name text not null,
        about text,
        primary key (machine_id, bot_id)
      );
    `
  }
]
