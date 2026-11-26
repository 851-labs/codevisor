import type Database from "better-sqlite3"

import { runBlockingDataUpgrades } from "./data-upgrades.js"
import { markFirstRunProjectsPending } from "./machine-settings-service.js"
import { migrations } from "./migrations.js"
import { installNavigationJournal } from "./navigation-journal.js"
import {
  describeOrphanResolution,
  resolveOrphanedRows,
  type OrphanResolution
} from "./orphaned-rows.js"
import { migrateProjectLocationState } from "./project-location-state.js"
import { integer, rowReader } from "./row-reader.js"
import type { CodevisorDatabaseConfig } from "./service.js"

const schemaMigrationRows = rowReader({ id: integer })

const loadAppliedMigrations = (sqlite: Database.Database): Set<number> => {
  sqlite.exec(
    "create table if not exists schema_migrations (id integer primary key, name text not null)"
  )
  return new Set(
    sqlite
      .prepare("select id from schema_migrations")
      .all()
      .map((row) => schemaMigrationRows.one(row).id)
  )
}

const applyDeclaredMigrations = (
  sqlite: Database.Database,
  config: CodevisorDatabaseConfig,
  applied: Set<number>,
  names: Array<string>
): void => {
  for (const migration of migrations) {
    if (applied.has(migration.id)) {
      continue
    }
    sqlite.exec(migration.sql)
    migration.run?.(sqlite, config)
    sqlite
      .prepare("insert into schema_migrations (id, name) values (?, ?)")
      .run(migration.id, migration.name)
    names.push(migration.name)
  }
}

const initializeUpdateState = (sqlite: Database.Database): void => {
  sqlite
    .prepare(
      `insert into update_state (
              id, current_version, latest_version, update_available, channel, checked_at, migration_state
            ) values (1, '0.1.0', '0.1.0', 0, 'development', null, 'idle')
            on conflict(id) do nothing`
    )
    .run()
}

const validateSchemaAndResetAdoption = (
  sqlite: Database.Database
): ReadonlyArray<OrphanResolution> => {
  const resolutions = resolveOrphanedRows(sqlite)
  sqlite.prepare("delete from instance_meta where key = 'adopted-server-id'").run()
  return resolutions
}

const logOrphanResolutions = (resolutions: ReadonlyArray<OrphanResolution>): void => {
  if (resolutions.length === 0) return

  const lines = resolutions.map((resolution) => `  ${describeOrphanResolution(resolution)}`)
  console.error(
    `Migrations applied the schema's delete rules to rows left behind:\n${lines.join("\n")}`
  )
}

export const runDatabaseMigrations = (
  sqlite: Database.Database,
  config: CodevisorDatabaseConfig
): Array<string> => {
  const applied = loadAppliedMigrations(sqlite)
  const isNewDatabase = applied.size === 0
  const names: Array<string> = []
  sqlite.pragma("foreign_keys = OFF")
  try {
    const transaction = sqlite.transaction((): ReadonlyArray<OrphanResolution> => {
      applyDeclaredMigrations(sqlite, config, applied, names)
      initializeUpdateState(sqlite)
      if (isNewDatabase) markFirstRunProjectsPending(sqlite)
      if (names.length === 0) return []
      return validateSchemaAndResetAdoption(sqlite)
    })
    logOrphanResolutions(transaction())
    runBlockingDataUpgrades(sqlite, config)
    migrateProjectLocationState(sqlite)
    installNavigationJournal(sqlite)
  } finally {
    sqlite.pragma("foreign_keys = ON")
  }
  return names
}
