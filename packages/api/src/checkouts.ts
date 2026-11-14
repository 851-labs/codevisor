import { Schema } from "effect"

import { WorkspaceGit } from "./git-review.js"

export const Checkout = Schema.Struct({
  id: Schema.String,
  serverId: Schema.String,
  projectId: Schema.String,
  path: Schema.String,
  worktreeId: Schema.optional(Schema.String),
  worktreeName: Schema.optional(Schema.String),
  git: Schema.optional(WorkspaceGit),
  createdAt: Schema.String,
  updatedAt: Schema.optional(Schema.String),
  retiredAt: Schema.optional(Schema.String)
})
export type Checkout = typeof Checkout.Type
