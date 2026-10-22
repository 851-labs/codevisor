import { attempt } from "./errors.js"
import {
  harnessPendingUpdateFromRow,
  harnessUpdateStateFromRow,
  updateFromRow
} from "./row-mappers.js"
import { harnessPendingUpdateRows, harnessUpdateStateRows, updateRows } from "./rows.js"
import type { ServiceContext } from "./service-context.js"
import type { CodevisorDatabaseService } from "./service.js"

export const makeUpdatesService = (
  context: ServiceContext
): Pick<
  CodevisorDatabaseService,
  | "listHarnessPendingUpdates"
  | "setHarnessPendingUpdate"
  | "clearHarnessPendingUpdate"
  | "listHarnessUpdateStates"
  | "setHarnessUpdateState"
  | "getUpdateInfo"
  | "setUpdateInfo"
> => {
  const { sqlite } = context

  return {
    listHarnessPendingUpdates: attempt("listHarnessPendingUpdates", () =>
      pendingUpdates(sqlite).map(harnessPendingUpdateFromRow)
    ),
    setHarnessPendingUpdate: (record) =>
      attempt("setHarnessPendingUpdate", () => {
        sqlite
          .prepare(pendingUpdateSql.upsert)
          .run(
            record.harnessId,
            record.state,
            record.targetVersion ?? null,
            record.requestedAt,
            record.startedAt ?? null,
            record.timeoutAt ?? null
          )
        return record
      }),
    clearHarnessPendingUpdate: (harnessId) =>
      attempt("clearHarnessPendingUpdate", () => {
        sqlite.prepare(pendingUpdateSql.delete).run(harnessId)
      }),
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

const pendingUpdates = (sqlite: ServiceContext["sqlite"]) =>
  harnessPendingUpdateRows.all(sqlite.prepare(pendingUpdateSql.all).all())

const harnessUpdateStates = (sqlite: ServiceContext["sqlite"]) =>
  harnessUpdateStateRows.all(sqlite.prepare(harnessUpdateStateSql.all).all())

const serverUpdateState = (sqlite: ServiceContext["sqlite"]) =>
  updateRows.one(sqlite.prepare(serverUpdateSql.current).get())

const pendingUpdateSql = {
  all: "select * from harness_pending_updates",
  upsert: `insert into harness_pending_updates (
              harness_id, state, target_version, requested_at, started_at, timeout_at
            ) values (?, ?, ?, ?, ?, ?)
            on conflict(harness_id) do update set
              state = excluded.state,
              target_version = excluded.target_version,
              requested_at = excluded.requested_at,
              started_at = excluded.started_at,
              timeout_at = excluded.timeout_at`,
  delete: "delete from harness_pending_updates where harness_id = ?"
}

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
