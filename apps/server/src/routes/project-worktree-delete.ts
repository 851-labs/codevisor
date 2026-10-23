import type { ServerResponse } from "node:http"

import type { Worktree } from "@codevisor/api"
import { rollbackFailedWorktree } from "@codevisor/worktrees"

import {
  getProjectOrFail,
  HttpFailure,
  localLocationOrFail,
  run,
  writeJson,
  type CodevisorServerServices
} from "../server-context.js"

export const deleteUnusedProjectWorktree = async (
  services: CodevisorServerServices,
  serverId: string,
  projectId: string,
  worktreeId: string,
  response: ServerResponse
): Promise<boolean> => {
  const project = await getProjectOrFail(services.db, projectId)
  const worktree = await projectWorktree(services, project.id, worktreeId)
  if (await worktreeInUse(services, worktree)) {
    throw new HttpFailure(409, `Worktree ${worktree.name} is in use by a chat or workspace`)
  }

  const location = localLocationOrFail(serverId, project)
  const environment = await (services.resolveGitEnvironment?.(location.folderPath) ?? process.env)
  await rollbackFailedWorktree(location.folderPath, worktree.path, worktree.branch, environment)
  await run(services.db.deleteWorktree(worktree.id))
  writeJson(response, 204, {})
  return true
}

const projectWorktree = async (
  services: CodevisorServerServices,
  projectId: string,
  worktreeId: string
): Promise<Worktree> => {
  const worktrees = await run(services.db.listWorktrees(projectId))
  const worktree = worktrees.find((candidate) => candidate.id.toLowerCase() === worktreeId)
  if (worktree === undefined) throw new HttpFailure(404, `Worktree not found: ${worktreeId}`)
  return worktree
}

const worktreeInUse = async (
  services: CodevisorServerServices,
  worktree: Worktree
): Promise<boolean> => {
  const sessions = await run(services.db.listSessions)
  const workspaces = await run(services.db.listWorkspaces)
  return (
    sessions.some((session) => usesWorktree(session, worktree)) ||
    workspaces.some((workspace) => workspace.rootDirectory === worktree.path)
  )
}

const usesWorktree = (
  session: { readonly projectId: string; readonly worktreeName?: string | undefined },
  worktree: Worktree
): boolean => session.projectId === worktree.projectId && session.worktreeName === worktree.name
