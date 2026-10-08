import {
  isoTimestamp,
  type EventEnvelope,
  type NavigationFolder,
  type NavigationRecords,
  type NavigationSetting,
  type PutNavigationRecordsRequest
} from "@codevisor/api"
import type Database from "better-sqlite3"
import type { Effect } from "effect"

import { attempt, type DatabaseError } from "./errors.js"
import { canonicalUuid } from "./ids.js"
import { eventFromRow } from "./row-mappers.js"
import type { EventRow } from "./rows.js"
import type { ServiceContext } from "./service-context.js"

/// Replicated navigation records (see migration 61).
export interface NavigationRecordsDatabase {
  readonly listNavigationRecords: Effect.Effect<NavigationRecords, DatabaseError>
  /// Keeps each record only where its revision is newer than the stored one.
  /// Returns what the machine now holds for the written ids, and the
  /// `navigation.changed` events the write journaled (to wake readers).
  readonly putNavigationRecords: (request: PutNavigationRecordsRequest) => Effect.Effect<
    {
      readonly records: NavigationRecords
      readonly events: ReadonlyArray<EventEnvelope>
    },
    DatabaseError
  >
}

interface NavigationFolderRow {
  readonly id: string
  readonly name: string
  readonly position: string
  readonly collapsed: number
  readonly deleted: number
  readonly revision: string
}

interface NavigationSettingRow {
  readonly key: string
  readonly value: string
  readonly revision: string
}

export const navigationFolderFromRow = (row: NavigationFolderRow): NavigationFolder => ({
  id: row.id,
  name: row.name,
  position: row.position,
  collapsed: row.collapsed === 1,
  deleted: row.deleted === 1,
  revision: row.revision
})

export const navigationSettingFromRow = (row: NavigationSettingRow): NavigationSetting => ({
  key: row.key,
  value: row.value,
  revision: row.revision
})

const selectFolder = "select * from nav_folders where id = ?"
const selectSetting = "select * from nav_settings where key = ?"

/// The stored folders and settings with these ids, for a navigation delta.
export const navigationRecordsFor = (
  sqlite: Database.Database,
  folderIds: Iterable<string>,
  settingKeys: Iterable<string>
): NavigationRecords => ({
  folders: [...folderIds]
    .map((id) => sqlite.prepare(selectFolder).get(id) as NavigationFolderRow | undefined)
    .filter((row) => row !== undefined)
    .map(navigationFolderFromRow),
  settings: [...settingKeys]
    .map((key) => sqlite.prepare(selectSetting).get(key) as NavigationSettingRow | undefined)
    .filter((row) => row !== undefined)
    .map(navigationSettingFromRow)
})

/// The records as a snapshot or delta carries them: omitted while empty, so
/// payloads from a machine without records keep their old shape.
export const nonEmptyRecords = (records: NavigationRecords): Partial<NavigationRecords> => ({
  ...(records.folders.length === 0 ? {} : { folders: records.folders }),
  ...(records.settings.length === 0 ? {} : { settings: records.settings })
})

/// Every stored folder (tombstones included) and setting.
export const allNavigationRecords = (sqlite: Database.Database): NavigationRecords => ({
  folders: (
    sqlite.prepare("select * from nav_folders order by position, id").all() as NavigationFolderRow[]
  ).map(navigationFolderFromRow),
  settings: (
    sqlite.prepare("select * from nav_settings order by key").all() as NavigationSettingRow[]
  ).map(navigationSettingFromRow)
})

export const makeNavigationRecordsService = (
  context: ServiceContext
): NavigationRecordsDatabase => {
  const { sqlite } = context
  return {
    listNavigationRecords: attempt("listNavigationRecords", () => allNavigationRecords(sqlite)),
    putNavigationRecords: (request: PutNavigationRecordsRequest) =>
      attempt("putNavigationRecords", () =>
        sqlite.transaction(() => {
          const { cursor } = sqlite
            .prepare("select coalesce(max(id), 0) as cursor from events")
            .get() as { readonly cursor: number }
          const now = isoTimestamp()
          // Last writer wins by revision: an older or equal stamp is a no-op,
          // so replaying a copy from another machine changes nothing.
          const folder = sqlite.prepare(
            `insert into nav_folders (id, name, position, collapsed, deleted, revision, updated_at)
               values (?, ?, ?, ?, ?, ?, ?)
             on conflict(id) do update set
               name = excluded.name, position = excluded.position,
               collapsed = excluded.collapsed, deleted = excluded.deleted,
               revision = excluded.revision, updated_at = excluded.updated_at
             where excluded.revision > nav_folders.revision`
          )
          const setting = sqlite.prepare(
            `insert into nav_settings (key, value, revision, updated_at) values (?, ?, ?, ?)
             on conflict(key) do update set
               value = excluded.value, revision = excluded.revision,
               updated_at = excluded.updated_at
             where excluded.revision > nav_settings.revision`
          )
          const folderIds = (request.folders ?? []).map((record) => {
            const id = canonicalUuid(record.id)
            folder.run(
              id,
              record.name,
              record.position,
              record.collapsed ? 1 : 0,
              record.deleted ? 1 : 0,
              record.revision,
              now
            )
            return id
          })
          const settingKeys = (request.settings ?? []).map((record) => {
            setting.run(record.key, record.value, record.revision, now)
            return record.key
          })
          return {
            records: navigationRecordsFor(sqlite, folderIds, settingKeys),
            events: (
              sqlite
                .prepare(
                  "select * from events where id > ? and kind = 'navigation.changed' order by id"
                )
                .all(cursor) as ReadonlyArray<EventRow>
            ).map(eventFromRow)
          }
        })()
      )
  }
}
