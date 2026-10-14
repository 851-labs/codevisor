import type Database from "better-sqlite3"

import type { CodevisorDatabaseConfig } from "./service.js"

export interface Migration {
  readonly id: number
  readonly name: string
  readonly sql: string
  readonly run?: (sqlite: Database.Database, config: CodevisorDatabaseConfig) => void
}
