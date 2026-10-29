import type { Sandbox } from "@codevisor/api"

import { createdHere, creatorOf } from "./sandbox-manager.js"
import { OPTIONAL_LINKS, optionalLinks } from "./sandbox-profile-record.js"
import type { SandboxDeps } from "./sandboxes.js"

export interface RetiredWorkspace {
  readonly workspaceId: string
  readonly name: string
}

const archivedRecord = (
  deps: SandboxDeps,
  machine: Sandbox,
  workspace: RetiredWorkspace
): Sandbox => ({
  id: machine.id,
  name: machine.name,
  projectId: machine.projectId,
  provider: machine.provider,
  ...optionalLinks(machine, OPTIONAL_LINKS),
  state: "archived",
  createdAt: machine.createdAt,
  createdOn: creatorOf(deps, machine),
  workspaceId: workspace.workspaceId,
  workspaceName: workspace.name
})

export const leavePlaceholder = async (
  deps: SandboxDeps,
  machine: Sandbox,
  workspace: RetiredWorkspace
): Promise<void> => {
  const archived = archivedRecord(deps, machine, workspace)
  if (createdHere(deps, archived)) return keepPlaceholder(deps, archived, workspace)

  await deps.records.put({ ...archived, placeholderPending: true })
}

export const adoptPlaceholders = async (deps: SandboxDeps): Promise<void> => {
  for (const machine of await deps.records.list()) {
    if (isPendingHere(deps, machine)) {
      await keepPlaceholder(deps, machine, {
        workspaceId: machine.workspaceId,
        name: machine.workspaceName
      })
    }
  }
}

type PendingPlaceholder = Sandbox & { readonly workspaceId: string; readonly workspaceName: string }

const isPendingHere = (deps: SandboxDeps, machine: Sandbox): machine is PendingPlaceholder =>
  machine.placeholderPending === true &&
  createdHere(deps, machine) &&
  machine.workspaceId !== undefined &&
  machine.workspaceName !== undefined

const keepPlaceholder = async (
  deps: SandboxDeps,
  archived: Sandbox,
  workspace: RetiredWorkspace
): Promise<void> => {
  const { placeholderPending: _pending, ...settled } = archived
  const kept = await deps.localWorkspaces.keepArchived({
    ...workspace,
    projectId: archived.projectId,
    sandboxId: archived.id
  })
  if (kept && settled.profileId !== undefined) await deps.records.put(settled)
  else await deps.records.remove(archived.id)
}
