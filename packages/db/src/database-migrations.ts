import type Database from "better-sqlite3"

import { runBlockingDataUpgrades } from "./data-upgrades.js"
import { migrations } from "./migrations.js"
import { installNavigationJournal } from "./navigation-journal.js"
import { migrateProjectLocationState } from "./project-location-state.js"
import type { CodevisorDatabaseConfig } from "./service.js"

const loadAppliedMigrations = (sqlite: Database.Database): Set<number> => {
  sqlite.exec(
    "create table if not exists schema_migrations (id integer primary key, name text not null)"
  )
  return new Set(
    sqlite
      .prepare("select id from schema_migrations")
      .all()
      .map((row) => (row as { readonly id: number }).id)
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

const validateSchemaAndResetAdoption = (sqlite: Database.Database): void => {
  const violations = sqlite.pragma("foreign_key_check") as ReadonlyArray<unknown>
  if (violations.length > 0) {
    throw new Error(`Migration left foreign key violations: ${JSON.stringify(violations)}`)
  }
  // New schemas may introduce more identity-bearing rows.
  sqlite.prepare("delete from instance_meta where key = 'adopted-server-id'").run()
}

export const runDatabaseMigrations = (
  sqlite: Database.Database,
  config: CodevisorDatabaseConfig
): Array<string> => {
  const applied = loadAppliedMigrations(sqlite)
  const names: Array<string> = []
  // Table rebuilds (drop + rename) would cascade-delete child rows under enforced foreign
  // keys, and `pragma foreign_keys` is a no-op inside a transaction — toggle it out here.
  sqlite.pragma("foreign_keys = OFF")
  try {
    const transaction = sqlite.transaction(() => {
      applyDeclaredMigrations(sqlite, config, applied, names)
      initializeUpdateState(sqlite)
      if (names.length > 0) {
        validateSchemaAndResetAdoption(sqlite)
      }
    })
    transaction()
    // Required data upgrades run in bounded, checkpointed transactions
    // after the schema commit. Startup remains blocking, but the old tables
    // stay untouched and an interrupted process resumes from durable rows.
    runBlockingDataUpgrades(sqlite, config)
    migrateProjectLocationState(sqlite)
    installNavigationJournal(sqlite)
  } finally {
    sqlite.pragma("foreign_keys = ON")
  }
  return names
}
