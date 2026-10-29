import type { Project } from "@codevisor/api"
import type { CodevisorDatabaseService } from "@codevisor/db"

import { run } from "../server-context.js"
import { SANDBOX_RESTORE_LABEL } from "./sandbox-watch.js"
import type { ArchivedWorkspace, SandboxDeps } from "./sandboxes.js"

export type SandboxEventPublisher = (
  kind: "workspace.updated" | "workspace.deleted" | "sync.changed",
  id: string,
  payload: unknown
) => Promise<unknown>

export interface SandboxEvents {
  publish: SandboxEventPublisher
}

type WorkspaceDatabase = Pick<
  CodevisorDatabaseService,
  "upsertWorkspace" | "deleteWorkspace" | "listWorkspaces"
>

export const makeSandboxLocalWorkspaces = (
  db: WorkspaceDatabase,
  projects: SandboxDeps["projects"],
  events: SandboxEvents
): SandboxDeps["localWorkspaces"] => ({
  keepArchived: async (placeholder) => {
    const project = await projects.get(placeholder.projectId)
    if (project === undefined) return false

    const workspace = await run(db.upsertWorkspace(archivedPlaceholder(placeholder, project)))
    await events.publish("workspace.updated", workspace.id, workspace)
    return true
  },
  remove: async (workspaceId) => {
    const exists = (await run(db.listWorkspaces)).some((workspace) => workspace.id === workspaceId)
    if (!exists) return

    await run(db.deleteWorkspace(workspaceId))
    await events.publish("workspace.deleted", workspaceId, { id: workspaceId })
  }
})

const archivedPlaceholder = (placeholder: ArchivedWorkspace, project: Project) => ({
  id: placeholder.workspaceId,
  projectId: project.id,
  name: placeholder.name,
  hasCustomName: true,
  isArchived: true,
  labels: { [SANDBOX_RESTORE_LABEL]: placeholder.sandboxId }
})
