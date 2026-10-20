import { Schema } from "effect"

import { AttachmentRef } from "./sessions.js"

export const WorkspacePhotoSource = Schema.Literals(["message", "tool"])
export type WorkspacePhotoSource = typeof WorkspacePhotoSource.Type

export const WorkspacePhoto = Schema.Struct({
  attachment: AttachmentRef,
  sessionId: Schema.String,
  itemId: Schema.String,
  createdAt: Schema.String,
  source: WorkspacePhotoSource
})
export type WorkspacePhoto = typeof WorkspacePhoto.Type

export const WorkspacePhotoPage = Schema.Struct({
  photos: Schema.Array(WorkspacePhoto),
  nextBefore: Schema.optional(Schema.String)
})
export type WorkspacePhotoPage = typeof WorkspacePhotoPage.Type

export const WorkspaceMediaItem = Schema.Struct({
  ...WorkspacePhoto.fields,
  durationSeconds: Schema.optional(Schema.Number)
})
export type WorkspaceMediaItem = typeof WorkspaceMediaItem.Type

export const WorkspaceMediaPage = Schema.Struct({
  media: Schema.Array(WorkspaceMediaItem),
  nextBefore: Schema.optional(Schema.String)
})
export type WorkspaceMediaPage = typeof WorkspaceMediaPage.Type

export const WorkspaceLink = Schema.Struct({
  url: Schema.String,
  title: Schema.optional(Schema.String),
  sessionId: Schema.String,
  itemId: Schema.String,
  createdAt: Schema.String
})
export type WorkspaceLink = typeof WorkspaceLink.Type

export const WorkspaceLinkPage = Schema.Struct({
  links: Schema.Array(WorkspaceLink),
  nextBefore: Schema.optional(Schema.String)
})
export type WorkspaceLinkPage = typeof WorkspaceLinkPage.Type

export const WorkspaceFileChangeStatus = Schema.Literals(["added", "modified", "deleted"])
export type WorkspaceFileChangeStatus = typeof WorkspaceFileChangeStatus.Type

export const WorkspaceFileChange = Schema.Struct({
  path: Schema.String,
  added: Schema.Number,
  removed: Schema.Number,
  status: Schema.optional(WorkspaceFileChangeStatus),
  uncommitted: Schema.Boolean,
  changedAt: Schema.optional(Schema.String),
  sessionId: Schema.optional(Schema.String)
})
export type WorkspaceFileChange = typeof WorkspaceFileChange.Type

export const WorkspaceFileChanges = Schema.Struct({
  files: Schema.Array(WorkspaceFileChange),
  truncated: Schema.Boolean
})
export type WorkspaceFileChanges = typeof WorkspaceFileChanges.Type
