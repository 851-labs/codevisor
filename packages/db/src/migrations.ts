import type { Migration } from "./migration-types.js"
import { migrations01To08 } from "./migrations-01-08.js"
import { migrations09To29 } from "./migrations-09-29.js"
import { migrations30To33 } from "./migrations-30-33.js"
import { migrations34To45 } from "./migrations-34-45.js"
import { migrations46 } from "./migrations-46.js"
import { migrations47 } from "./migrations-47.js"
import { migrations48 } from "./migrations-48.js"
import { migrations49 } from "./migrations-49.js"
import { migrations50 } from "./migrations-50.js"

export type { Migration } from "./migration-types.js"

/// Every schema migration in order; the service applies the ones past the
/// database's recorded version inside one transaction each.
export const migrations: ReadonlyArray<Migration> = [
  ...migrations01To08,
  ...migrations09To29,
  ...migrations30To33,
  ...migrations34To45,
  ...migrations46,
  ...migrations47,
  ...migrations48,
  ...migrations49,
  ...migrations50
]
