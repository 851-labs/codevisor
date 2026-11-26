import Database from "better-sqlite3"
import { describe, expect, it, onTestFinished } from "vitest"

import { makeDatabase } from "./index.js"
import { migrations, type Migration } from "./migrations.js"
import { schemaFixture } from "./schema-fixture.js"
import { run, tempDatabase } from "./test-support.js"

const serverId = "machine-a"

const hangGuard = { timeout: 30_000 }

const valuesTheSchemaDoesNotConstrain = {
  "conversation_items.role": "user",
  "transcript_items.role": "user",
  "events.kind": "session.updated",
  "events.payload": "{}",
  "session_events.kind": "session.updated",
  "session_events.payload": "{}"
}

const migrateWithFixtureRowsBeforeEachStep = (
  filename: string,
  steps: ReadonlyArray<Migration>
): void => {
  const sqlite = new Database(filename)
  try {
    sqlite.pragma("foreign_keys = OFF")
    sqlite.exec(chainSql.schemaMigrations)
    const fixture = schemaFixture(sqlite, valuesTheSchemaDoesNotConstrain)
    sqlite.transaction(() => {
      for (const migration of steps) {
        fixture.seedRound()
        applyMigration(sqlite, filename, migration)
      }
      fixture.seedRound()
    })()
  } finally {
    sqlite.close()
  }
}

const applyMigration = (sqlite: Database.Database, filename: string, migration: Migration) => {
  sqlite.exec(migration.sql)
  migration.run?.(sqlite, { filename, serverId })
  sqlite.prepare(chainSql.recordMigration).run(migration.id, migration.name)
}

const chainSql = {
  schemaMigrations:
    "create table if not exists schema_migrations (id integer primary key, name text not null)",
  recordMigration: "insert into schema_migrations (id, name) values (?, ?)"
}

describe("the migration chain", () => {
  it(
    "opens a database whose every table held linked rows before every migration",
    hangGuard,
    async () => {
      const filename = tempDatabase()
      migrateWithFixtureRowsBeforeEachStep(filename, migrations.slice(0, -1))

      const db = await run(makeDatabase({ filename, serverId }))
      onTestFinished(() => run(db.close))

      expect(await run(db.migrate)).toEqual([])
    }
  )
})
