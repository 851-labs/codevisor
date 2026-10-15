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
