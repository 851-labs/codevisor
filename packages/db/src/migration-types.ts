import type Database from "better-sqlite3"
import type { CodevisorDatabaseConfig } from "./service.js"

export interface Migration {
  readonly id: number
  readonly name: string
  readonly sql: string
  /** Runs inside the migration transaction, after `sql`; use for backfills that need config values. */
  readonly run?: (sqlite: Database.Database, config: CodevisorDatabaseConfig) => void
}
