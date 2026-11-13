import type Database from "better-sqlite3"
import type { Effect } from "effect"

import { attempt, type DatabaseError } from "./errors.js"
import type { ServiceContext } from "./service-context.js"
import type { CodevisorDatabaseConfig } from "./service.js"

export interface DatabaseSpaceService {
  readonly releaseFreeSpace: Effect.Effect<void, DatabaseError>
}

export const makeDatabaseSpaceService = ({ sqlite }: ServiceContext): DatabaseSpaceService => ({
  releaseFreeSpace: attempt("releaseFreeSpace", () => {
    sqlite.pragma("incremental_vacuum")
  })
})

export const compactOnceForIncrementalVacuum = (
  sqlite: Database.Database,
  config: CodevisorDatabaseConfig
): void => {
  if (releasesSpaceIncrementally(sqlite)) return

  reportCompaction(config, 0)
  try {
    sqlite.pragma("auto_vacuum = INCREMENTAL")
    sqlite.exec(compactSql)
  } catch (cause) {
    console.error(`Could not compact the database: ${String(cause)}`)
  }
  reportCompaction(config, 1)
}

const incrementalAutoVacuum = 2

const compactSql = "vacuum"

const releasesSpaceIncrementally = (sqlite: Database.Database): boolean =>
  sqlite.pragma("auto_vacuum", { simple: true }) === incrementalAutoVacuum

const reportCompaction = (config: CodevisorDatabaseConfig, completed: number): void => {
  config.onDataUpgradeProgress?.({
    state: completed === 1 ? "completed" : "running",
    id: "incremental-vacuum-v1",
    name: "Freeing up disk space",
    completed,
    total: 1
  })
}
