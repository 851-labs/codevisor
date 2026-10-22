import { attempt } from "./errors.js"
import { harnessUpdateStateFromRow, updateFromRow } from "./row-mappers.js"
import { harnessUpdateStateRows, updateRows } from "./rows.js"
import type { ServiceContext } from "./service-context.js"
import type { CodevisorDatabaseService } from "./service.js"

export const makeUpdatesService = (
  context: ServiceContext
): Pick<
  CodevisorDatabaseService,
  "listHarnessUpdateStates" | "setHarnessUpdateState" | "getUpdateInfo" | "setUpdateInfo"
> => {
  const { sqlite } = context

  return {
    listHarnessUpdateStates: attempt("listHarnessUpdateStates", () =>
      harnessUpdateStates(sqlite).map(harnessUpdateStateFromRow)
    ),
    setHarnessUpdateState: (record) =>
      attempt("setHarnessUpdateState", () => {
        sqlite
          .prepare(harnessUpdateStateSql.upsert)
          .run(
            record.harnessId,
            record.info.installedVersion ?? null,
            record.info.latestVersion ?? null,
            record.info.updateAvailable ? 1 : 0,
            record.info.source ?? null,
            record.info.installOrigin ?? null,
            record.info.channel ?? null,
            record.info.checkedAt ?? null
          )
        return record
      }),
    getUpdateInfo: attempt("getUpdateInfo", () => updateFromRow(serverUpdateState(sqlite))),
    setUpdateInfo: (update) =>
      attempt("setUpdateInfo", () => {
        sqlite
          .prepare(serverUpdateSql.upsert)
          .run(
            update.currentVersion,
            update.latestVersion,
            update.updateAvailable ? 1 : 0,
            update.channel,
            update.checkedAt ?? null,
            update.migrationState
          )
        return update
      })
  }
}

const harnessUpdateStates = (sqlite: ServiceContext["sqlite"]) =>
  harnessUpdateStateRows.all(sqlite.prepare(harnessUpdateStateSql.all).all())

const serverUpdateState = (sqlite: ServiceContext["sqlite"]) =>
  updateRows.one(sqlite.prepare(serverUpdateSql.current).get())

const harnessUpdateStateSql = {
  all: "select * from harness_update_state",
  upsert: `insert into harness_update_state (
              harness_id, installed_version, latest_version, update_available,
              source, install_origin, channel, checked_at
            ) values (?, ?, ?, ?, ?, ?, ?, ?)
            on conflict(harness_id) do update set
              installed_version = excluded.installed_version,
              latest_version = excluded.latest_version,
              update_available = excluded.update_available,
              source = excluded.source,
              install_origin = excluded.install_origin,
              channel = excluded.channel,
              checked_at = excluded.checked_at`
}

const serverUpdateSql = {
  current: "select * from update_state where id = 1",
  upsert: `insert into update_state (
              id, current_version, latest_version, update_available, channel, checked_at, migration_state
            ) values (1, ?, ?, ?, ?, ?, ?)
            on conflict(id) do update set
              current_version = excluded.current_version,
              latest_version = excluded.latest_version,
              update_available = excluded.update_available,
              channel = excluded.channel,
              checked_at = excluded.checked_at,
              migration_state = excluded.migration_state`
}
