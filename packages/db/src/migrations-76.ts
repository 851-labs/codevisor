import type { Migration } from "./migration-types.js"

export const migrations76: ReadonlyArray<Migration> = [
  {
    id: 76,
    name: "fleet delivery",
    sql: `
      create table fleet_outbox (
        id text primary key,
        machine_id text not null,
        path text not null,
        args text not null,
        origin text not null,
        created_at text not null
      );
      create table fleet_deliveries (
        delivery_id text primary key,
        received_at text not null
      );
    `
  }
]
