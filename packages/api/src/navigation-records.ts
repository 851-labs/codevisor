import { Schema } from "effect"

/// A hybrid logical clock stamp: zero-padded milliseconds, a zero-padded
/// counter, and the writing device. Stamps compare as strings, so every
/// machine and client orders two writes the same way.
export const NavigationRevision = Schema.String.check(
  Schema.isPattern(/^\d{13}-\d{6}-[A-Za-z0-9._-]{1,64}$/)
)
export type NavigationRevision = typeof NavigationRevision.Type

/// A sidebar folder, replicated to every machine. `deleted` folders are
/// tombstones: they stay so an older copy can never bring them back.
export const NavigationFolder = Schema.Struct({
  id: Schema.String,
  name: Schema.String,
  /// Its place among top-level sidebar items, in the workspaces'
  /// `sidebarPosition` key space.
  position: Schema.String,
  collapsed: Schema.Boolean,
  deleted: Schema.Boolean,
  revision: NavigationRevision
})
export type NavigationFolder = typeof NavigationFolder.Type

/// An account-wide navigation setting, replicated to every machine: the
/// sidebar grouping (`sidebar.grouping`) and project order
/// (`project.order.<projectId>`).
export const NavigationSetting = Schema.Struct({
  key: Schema.String.check(Schema.isMaxLength(256)),
  value: Schema.String.check(Schema.isMaxLength(4096)),
  revision: NavigationRevision
})
export type NavigationSetting = typeof NavigationSetting.Type

/// Replicated navigation records. A write is kept only where its revision is
/// newer than the stored one; the response is what the machine now holds for
/// the written ids.
export const NavigationRecords = Schema.Struct({
  folders: Schema.Array(NavigationFolder),
  settings: Schema.Array(NavigationSetting)
})
export type NavigationRecords = typeof NavigationRecords.Type

export const PutNavigationRecordsRequest = Schema.Struct({
  folders: Schema.optional(Schema.Array(NavigationFolder)),
  settings: Schema.optional(Schema.Array(NavigationSetting))
})
export type PutNavigationRecordsRequest = typeof PutNavigationRecordsRequest.Type
