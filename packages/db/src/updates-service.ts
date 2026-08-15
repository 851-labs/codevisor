import { attempt } from "./errors.js"
import {
  harnessPendingUpdateFromRow,
  harnessUpdateStateFromRow,
  updateFromRow
} from "./row-mappers.js"
import type { HarnessPendingUpdateRow, HarnessUpdateStateRow, UpdateRow } from "./rows.js"
import type { CodevisorDatabaseService } from "./service.js"
import type { ServiceContext } from "./service-context.js"

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
      (
        sqlite
          .prepare("select * from harness_pending_updates")
          .all() as Array<HarnessPendingUpdateRow>
      ).map(harnessPendingUpdateFromRow)
    ),
    setHarnessPendingUpdate: (record) =>
      attempt("setHarnessPendingUpdate", () => {
        sqlite
          .prepare(
            `insert into harness_pending_updates (
              harness_id, state, target_version, requested_at, started_at, timeout_at
            ) values (?, ?, ?, ?, ?, ?)
            on conflict(harness_id) do update set
              state = excluded.state,
              target_version = excluded.target_version,
              requested_at = excluded.requested_at,
              started_at = excluded.started_at,
              timeout_at = excluded.timeout_at`
          )
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
        sqlite.prepare("delete from harness_pending_updates where harness_id = ?").run(harnessId)
      }),
    listHarnessUpdateStates: attempt("listHarnessUpdateStates", () =>
      (
        sqlite.prepare("select * from harness_update_state").all() as Array<HarnessUpdateStateRow>
      ).map(harnessUpdateStateFromRow)
    ),
    setHarnessUpdateState: (record) =>
      attempt("setHarnessUpdateState", () => {
        sqlite
          .prepare(
            `insert into harness_update_state (
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
          )
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
    getUpdateInfo: attempt("getUpdateInfo", () =>
      updateFromRow(sqlite.prepare("select * from update_state where id = 1").get() as UpdateRow)
    ),
    setUpdateInfo: (update) =>
      attempt("setUpdateInfo", () => {
        sqlite
          .prepare(
            `insert into update_state (
              id, current_version, latest_version, update_available, channel, checked_at, migration_state
            ) values (1, ?, ?, ?, ?, ?, ?)
            on conflict(id) do update set
              current_version = excluded.current_version,
              latest_version = excluded.latest_version,
              update_available = excluded.update_available,
              channel = excluded.channel,
              checked_at = excluded.checked_at,
              migration_state = excluded.migration_state`
          )
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
