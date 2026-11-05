import type { Migration } from "./migration-types.js"

export const migrations94: ReadonlyArray<Migration> = [
  {
    id: 94,
    name: "bot mascot hat and eyewear colors",
    sql: `
      alter table bots add column mascot_hat_color text not null default 'auto';
      alter table bots add column mascot_eyewear_color text not null default 'auto';
    `
  }
]
