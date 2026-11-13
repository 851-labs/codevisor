import type Database from "better-sqlite3"

export const configureConnection = (sqlite: Database.Database): void => {
  sqlite.pragma("auto_vacuum = INCREMENTAL")
  sqlite.pragma("foreign_keys = ON")
  sqlite.pragma("journal_mode = WAL")
}
