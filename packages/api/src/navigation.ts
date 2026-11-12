import { Schema } from "effect"

import { Checkout } from "./checkouts.js"
import { Project } from "./projects.js"
import { SessionSummary } from "./sessions.js"
import { Workspace, WorkspacePane } from "./workspaces.js"

export const NavigationSnapshot = Schema.Struct({
  eventCursor: Schema.Number,
  projects: Schema.Array(Project),
  sessions: Schema.Array(SessionSummary),
  workspaces: Schema.Array(Workspace),
  panes: Schema.Array(WorkspacePane),
  checkouts: Schema.Array(Checkout)
})
export type NavigationSnapshot = typeof NavigationSnapshot.Type

export const NavigationDelta = Schema.Struct({
  ...NavigationSnapshot.fields,
  deleted: Schema.Array(
    Schema.Struct({
      table: Schema.Literals([
        "projects",
        "sessions",
        "workspaces",
        "workspace_panes",
        "checkouts"
      ]),
      id: Schema.String
    })
  )
})
export type NavigationDelta = typeof NavigationDelta.Type
