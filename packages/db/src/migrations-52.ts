import type { Migration } from "./migration-types.js"

export const migrations52: ReadonlyArray<Migration> = [
  {
    id: 52,
    name: "index the retired session event journal's chat item reference",
    // Superseded by migration 53, which drops the retired journal outright.
    // Kept as a no-op so databases that recorded it stay in sequence.
    sql: ""
  }
]
