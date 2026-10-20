import type { Workspace } from "@codevisor/api"
import type { OwnedBranch } from "@codevisor/worktrees"

import type { CodevisorServerServices } from "./server-context-types.js"
import { run } from "./server-http.js"

export const workspaceOwnedBranch = async (
  services: CodevisorServerServices,
  workspace: Workspace
): Promise<OwnedBranch | undefined> => {
  const worktree = (await run(services.db.listWorktrees(workspace.projectId))).find(
    (candidate) => candidate.path === workspace.rootDirectory
  )
  if (worktree === undefined) return undefined

  return { name: worktree.branch, ownedSince: earlier(worktree.createdAt, workspace.createdAt) }
}

export const folderOwnedBranch = async (
  services: CodevisorServerServices,
  folder: string
): Promise<OwnedBranch | undefined> => {
  const workspace = (await run(services.db.listWorkspaces)).find(
    (candidate) => !candidate.isArchived && candidate.rootDirectory === folder
  )
  if (workspace === undefined) return undefined

  return workspaceOwnedBranch(services, workspace)
}

const earlier = (first: string, second: string): string =>
  Date.parse(first) <= Date.parse(second) ? first : second
