import { Schema } from "effect"

import { Project } from "./projects.js"
import { SessionSummary } from "./sessions.js"
import { Workspace, WorkspacePane } from "./workspaces.js"

export const NavigationSnapshot = Schema.Struct({
  eventCursor: Schema.Number,
  projects: Schema.Array(Project),
  sessions: Schema.Array(SessionSummary),
  workspaces: Schema.Array(Workspace),
  panes: Schema.Array(WorkspacePane)
})
export type NavigationSnapshot = typeof NavigationSnapshot.Type

export const NavigationDelta = Schema.Struct({
  ...NavigationSnapshot.fields,
  deleted: Schema.Array(
    Schema.Struct({
      table: Schema.Literals(["projects", "sessions", "workspaces", "workspace_panes"]),
      id: Schema.String
    })
  )
})
export type NavigationDelta = typeof NavigationDelta.Type
