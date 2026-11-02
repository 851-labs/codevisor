import type { Migration } from "./migration-types.js"

export const migrations90: ReadonlyArray<Migration> = [
  {
    id: 90,
    name: "bot mascots",
    sql: `
      alter table bots add column mascot_color text not null default 'sunny';
      alter table bots add column mascot_hat text not null default 'none';
      alter table bots add column mascot_eyewear text not null default 'none';
      update bots set mascot_color = case (
        select count(*) from bots older
        where older.created_at < bots.created_at
          or (older.created_at = bots.created_at and older.id < bots.id)
      ) % 8
        when 0 then 'sunny'
        when 1 then 'mint'
        when 2 then 'lilac'
        when 3 then 'bubblegum'
        when 4 then 'sky'
        when 5 then 'tomato'
        when 6 then 'electric'
        else 'dream'
      end;
    `
  }
]
