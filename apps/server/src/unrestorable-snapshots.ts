import type { ArchivedWorktree, Project } from "@codevisor/api"
import { worktreeNameAt } from "@codevisor/db"
import { deleteSnapshot } from "@codevisor/worktrees"

import type { CodevisorServerServices } from "./server-context-types.js"
import { localLocationOrFail, run } from "./server-http.js"

export const forgetUnrestorableSnapshots = async (
  services: CodevisorServerServices,
  serverId: string
): Promise<void> => {
  const restorable = await restorableWorktrees(services)
  const environment = await (services.resolveGitEnvironment?.() ?? Promise.resolve(process.env))

  for (const project of await run(services.db.listProjects)) {
    const repoDir = localRepoDir(project, serverId)
    if (repoDir === undefined) continue

    for (const archived of await run(services.db.listArchivedWorktrees(project.id))) {
      if (!isForgettable(archived, serverId, restorable)) continue

      await deleteSnapshot(repoDir, archived.id, environment)
      await run(services.db.deleteArchivedWorktree(archived.id))
    }
  }
}

const restorableWorktrees = async (
  services: CodevisorServerServices
): Promise<ReadonlySet<string>> => {
  const keys = new Set<string>()
  for (const workspace of await run(services.db.listWorkspaces)) {
    addKey(keys, workspace.projectId, workspace.rootDirectory)
  }

  const checkoutIds = new Set((await run(services.db.listSessions)).map((chat) => chat.checkoutId))
  for (const checkout of await run(services.db.listCheckouts)) {
    if (checkoutIds.has(checkout.id)) addKey(keys, checkout.projectId, checkout.path)
  }
  return keys
}

const addKey = (keys: Set<string>, projectId: string, path: string | undefined): void => {
  if (path === undefined) return

  const name = worktreeNameAt(projectId, path)
  if (name !== undefined) keys.add(worktreeKey(projectId, name))
}

const worktreeKey = (projectId: string, name: string): string =>
  `${projectId.toLowerCase()}/${name}`

const isForgettable = (
  archived: ArchivedWorktree,
  serverId: string,
  restorable: ReadonlySet<string>
): boolean =>
  archived.serverId === serverId &&
  archived.state === "complete" &&
  !restorable.has(worktreeKey(archived.projectId, archived.originalName))

const localRepoDir = (project: Project, serverId: string): string | undefined => {
  try {
    return localLocationOrFail(serverId, project).folderPath
  } catch {
    return undefined
  }
}
