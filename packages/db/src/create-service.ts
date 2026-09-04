import type Database from "better-sqlite3"
import { Effect } from "effect"
import { makeAuthService } from "./auth-service.js"
import { runBlockingDataUpgrades } from "./data-upgrades.js"
import { attempt } from "./errors.js"
import { makeEventsService } from "./events-service.js"
import { makeFilesService } from "./files-service.js"
import { makeHarnessService } from "./harness-service.js"
import { makeMcpService } from "./mcp-service.js"
import { migrations } from "./migrations.js"
import { makeProjectsService } from "./projects-service.js"
import { makePromptQueueService } from "./prompt-queue-service.js"
import type { CodevisorDatabaseConfig, CodevisorDatabaseService } from "./service.js"
import { createServiceContext } from "./service-context.js"
import { makeSessionsService } from "./sessions-service.js"
import { makeTranscriptService } from "./transcript-service.js"
import { makeSyncService } from "./sync-service.js"
import { makeUpdatesService } from "./updates-service.js"
import { makeWorkspacesService } from "./workspaces-service.js"
import { makeWorktreesService } from "./worktrees-service.js"

export const createService = (
  sqlite: Database.Database,
  config: CodevisorDatabaseConfig
): CodevisorDatabaseService => {
  const migrate = attempt("migrate", () => {
    sqlite.exec(
      "create table if not exists schema_migrations (id integer primary key, name text not null)"
    )
    const applied = new Set(
      sqlite
        .prepare("select id from schema_migrations")
        .all()
        .map((row) => (row as { readonly id: number }).id)
    )
    const names: Array<string> = []
    // Table rebuilds (drop + rename) would cascade-delete child rows under enforced foreign
    // keys, and `pragma foreign_keys` is a no-op inside a transaction — toggle it out here.
    sqlite.pragma("foreign_keys = OFF")
    try {
      const transaction = sqlite.transaction(() => {
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
        sqlite
          .prepare(
            `insert into update_state (
              id, current_version, latest_version, update_available, channel, checked_at, migration_state
            ) values (1, '0.1.0', '0.1.0', 0, 'development', null, 'idle')
            on conflict(id) do nothing`
          )
          .run()
        if (names.length > 0) {
          const violations = sqlite.pragma("foreign_key_check") as ReadonlyArray<unknown>
          if (violations.length > 0) {
            throw new Error(`Migration left foreign key violations: ${JSON.stringify(violations)}`)
          }
          // New schemas may introduce more identity-bearing rows.
          sqlite.prepare("delete from instance_meta where key = 'adopted-server-id'").run()
        }
      })
      transaction()
      // Required data upgrades run in bounded, checkpointed transactions
      // after the schema commit. Startup remains blocking, but the old tables
      // stay untouched and an interrupted process resumes from durable rows.
      runBlockingDataUpgrades(sqlite, config)
    } finally {
      sqlite.pragma("foreign_keys = ON")
    }
    return names
  })

  const context = createServiceContext(sqlite, config)

  return {
    migrate,
    close: Effect.sync(() => sqlite.close()),
    ...makeProjectsService(context),
    ...makeWorktreesService(context),
    ...makeWorkspacesService(context),
    ...makeSessionsService(context),
    ...makeTranscriptService(context),
    ...makeEventsService(context),
    ...makePromptQueueService(context),
    ...makeFilesService(context),
    ...makeHarnessService(context),
    ...makeMcpService(context),
    ...makeAuthService(context),
    ...makeUpdatesService(context),
    ...makeSyncService(context)
  }
}
