import type { Migration } from "./migration-types.js"

export const migrations59: ReadonlyArray<Migration> = [
  {
    id: 59,
    name: "project default run location",
    sql: `
      alter table projects add column default_run_location text;
    `
  }
]
