import type { Migration } from "./migration-types.js"

export const migrations72: ReadonlyArray<Migration> = [
  {
    id: 72,
    name: "remove browser preference",
    sql: `delete from instance_meta where key = 'browser-preference';`
  }
]
