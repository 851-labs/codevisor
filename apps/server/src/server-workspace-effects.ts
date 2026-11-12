import type { ArchivedWorktree, Checkout, SessionSummary, Workspace } from "@codevisor/api"
import { isoTimestamp } from "@codevisor/api"
import {
  legacyWorktreeTrashRoot,
  worktreeNameAt,
  worktreePath,
  worktreePathBeside,
  worktreeTrashRoot
} from "@codevisor/db"
import type { OwnedBranch } from "@codevisor/git-hosts"
import {
  deleteSnapshot,
  removeArchivedWorktreeFiles,
  restoreWorktree,
  snapshotWorktree,
  sweepWorktreeTrash
} from "@codevisor/worktrees"

import type { CodevisorServerServices, RouteState } from "./server-context-types.js"
import {
  existingDirectory,
  getProjectOrFail,
  localLocationOrFail,
  run,
  swallowError
} from "./server-http.js"
import { workspaceOwnedBranch } from "./workspace-owned-branch.js"
import { settleCleanup, workspaceTerminalKeys } from "./workspace-runtime.js"
import { withWorktreeLifecycle } from "./worktree-lifecycle.js"

export { worktreeTrashRoot }

export const sweepTrashedWorktrees = async (): Promise<void> => {
  await Promise.all([
    sweepWorktreeTrash(worktreeTrashRoot()),
    sweepWorktreeTrash(legacyWorktreeTrashRoot())
  ])
}

export const sessionIsArchived = async (
  services: CodevisorServerServices,
  session: Pick<SessionSummary, "workspaceId" | "isArchived">
): Promise<boolean> => {
  if (session.isArchived === true) return true
  const workspaceId = session.workspaceId
  if (workspaceId === undefined) return false
  return (await run(services.db.findBotOwning({ workspaceId })))?.isArchived === true
}

export const archivedChatRefusal = async (
  services: CodevisorServerServices,
  session: Pick<SessionSummary, "workspaceId" | "isArchived">,
  action: string
): Promise<string | undefined> => {
  if (!(await sessionIsArchived(services, session))) return undefined
  const shownArchived = (await run(services.db.listWorkspaces)).some(
    (workspace) =>
      workspace.isArchived && workspace.id.toLowerCase() === session.workspaceId?.toLowerCase()
  )
  return shownArchived ? `Restore the workspace before ${action}` : "This chat is archived"
}

const startAgentSessionCloses = (
  services: CodevisorServerServices,
  agentSessionId: string
): Array<Promise<void>> => {
  if (agentSessionId.length === 0) return []
  return [run(services.agents.closeAgentSession(agentSessionId))]
}

export const retireSessionRuntime = async (
  services: CodevisorServerServices,
  session: SessionSummary
): Promise<void> => {
  /* v8 ignore next */
  const agentSessionId = session.agentSessionId ?? ""
  const keys = new Set([session.id, agentSessionId].filter((id) => id.length > 0))
  let failure: unknown
  try {
    await settleCleanup(
      [...keys].flatMap((key) => [
        run(services.terminal.closeTerminalForSession(key)),
        run(services.terminal.closeTerminalsForSessionPrefix(`${key}:`))
      ])
    )
  } catch (error) {
    failure = error
  }
  await settleCleanup([
    ...startAgentSessionCloses(services, agentSessionId),
    services.mcp?.closeSession(session.id) ?? Promise.resolve()
  ])
  if (failure !== undefined) throw failure
}

export type RetiredTurnState = Pick<
  RouteState,
  "activeTurnSessions" | "promptTurnReleases" | "turnHeldSessions"
>

export const forgetRetiredSessionTurn = (turns: RetiredTurnState, sessionId: string): void => {
  turns.promptTurnReleases.get(sessionId)?.()
  turns.activeTurnSessions.delete(sessionId)
  turns.turnHeldSessions.delete(sessionId)
}

export const forgetTurnIfArchived = async (
  services: CodevisorServerServices,
  turns: RetiredTurnState,
  sessionId: string
): Promise<void> => {
  const session = await run(services.db.getSessionSummary(sessionId)).catch(swallowError)
  if (session === undefined || !(await sessionIsArchived(services, session))) return
  forgetRetiredSessionTurn(turns, sessionId)
}

export interface WorkspaceRuntime {
  readonly sessions: ReadonlyArray<SessionSummary>
  readonly terminalKeys: ReadonlyArray<string>
}

export const captureWorkspaceRuntime = async (
  services: CodevisorServerServices,
  turns: RetiredTurnState,
  workspace: Workspace
): Promise<WorkspaceRuntime> => {
  const sessions = (await run(services.db.listSessions)).filter(
    (session) => session.workspaceId?.toLowerCase() === workspace.id.toLowerCase()
  )
  for (const session of sessions) forgetRetiredSessionTurn(turns, session.id)
  return { sessions, terminalKeys: await workspaceTerminalKeys(services, [workspace.id]) }
}

export const retireWorkspaceRuntime = async (
  services: CodevisorServerServices,
  runtime: WorkspaceRuntime
): Promise<void> => {
  await settleCleanup([
    ...runtime.terminalKeys.map((key) => run(services.terminal.closeTerminalForSession(key))),
    ...runtime.sessions.map((session) => retireSessionRuntime(services, session))
  ])
}

export interface ArchivedWorkspaceWorktree {
  readonly purged: Promise<void>
}

const nothingArchived: ArchivedWorkspaceWorktree = { purged: Promise.resolve() }

export const archiveWorkspaceWorktree = async (
  services: CodevisorServerServices,
  serverId: string,
  workspace: Workspace
): Promise<ArchivedWorkspaceWorktree> => {
  const rootDirectory = workspace.rootDirectory
  if (rootDirectory === undefined) return nothingArchived
  return archiveUnusedWorktree(services, serverId, workspace.projectId, rootDirectory)
}

export const archiveUnusedWorktree = async (
  services: CodevisorServerServices,
  serverId: string,
  projectId: string,
  path: string
): Promise<ArchivedWorkspaceWorktree> => {
  if (await checkoutStillInUse(services, serverId, path)) return nothingArchived
  const worktree = (await run(services.db.listWorktrees(projectId))).find(
    (candidate) => candidate.serverId === serverId && candidate.path === path
  )
  if (worktree === undefined) return nothingArchived

  const project = await getProjectOrFail(services.db, projectId)
  const location = localLocationOrFail(serverId, project)
  const environment = await (services.resolveGitEnvironment?.() ?? Promise.resolve(process.env))

  const snapshot = await snapshotWorktree(
    location.folderPath,
    worktree.path,
    worktree.id,
    environment
  )
  const archivedAt = isoTimestamp()
  await run(
    services.db.createArchivedWorktree({
      id: worktree.id,
      projectId: worktree.projectId,
      serverId: worktree.serverId,
      originalName: worktree.name,
      branch: worktree.branch,
      parentSha: snapshot.parentSha,
      snapshotRef: snapshot.snapshotRef,
      createdAt: archivedAt,
      state: "pending"
    })
  )
  const trashed = await removeArchivedWorktreeFiles(
    location.folderPath,
    worktree.path,
    worktree.branch,
    { trashRoot: worktreeTrashRoot(), worktreeId: worktree.id, env: environment }
  )
  await run(
    services.db.createArchivedWorktree({
      id: worktree.id,
      projectId: worktree.projectId,
      serverId: worktree.serverId,
      originalName: worktree.name,
      branch: worktree.branch,
      parentSha: snapshot.parentSha,
      snapshotRef: snapshot.snapshotRef,
      createdAt: archivedAt,
      state: "complete"
    })
  )
  await run(services.db.deleteWorktree(worktree.id))
  return { purged: trashed.purged }
}

const checkoutStillInUse = async (
  services: CodevisorServerServices,
  serverId: string,
  path: string
): Promise<boolean> => {
  const checkout = (await run(services.db.listCheckouts)).find(
    (candidate) => candidate.serverId === serverId && candidate.path === path
  )
  return checkout !== undefined && (await run(services.db.isCheckoutInUse(checkout.id)))
}

export interface RestoredWorkspace {
  readonly workspace: Workspace
  readonly restoredFiles: boolean
}

export const restoreWorkspaceWorktree = async (
  services: CodevisorServerServices,
  serverId: string,
  workspace: Workspace
): Promise<RestoredWorkspace> => {
  const root = await withWorktreeLifecycle(
    services,
    workspace.rootDirectory ?? workspace.id,
    async () => restoreRootWorktree(services, serverId, workspace)
  )
  const others = await restoreChatWorktrees(services, serverId, root.workspace)
  return { workspace: root.workspace, restoredFiles: root.restoredFiles && others }
}

const restoreRootWorktree = async (
  services: CodevisorServerServices,
  serverId: string,
  workspace: Workspace
): Promise<RestoredWorkspace> => {
  const rootDirectory = workspace.rootDirectory
  if (rootDirectory === undefined) return { workspace, restoredFiles: true }
  const restored = await restoreArchivedWorktree(
    services,
    serverId,
    workspace.projectId,
    rootDirectory
  )
  if (restored.renamedTo === undefined) return { workspace, restoredFiles: restored.restoredFiles }
  const path = worktreePath(workspace.projectId, restored.renamedTo)
  const updated = await run(services.db.updateWorkspace(workspace.id, { rootDirectory: path }))
  return { workspace: updated, restoredFiles: restored.restoredFiles }
}

const restoreChatWorktrees = async (
  services: CodevisorServerServices,
  serverId: string,
  workspace: Workspace
): Promise<boolean> => {
  let restoredFiles = true
  for (const checkout of await chatCheckoutsBeside(services, serverId, workspace)) {
    const restored = await withWorktreeLifecycle(services, checkout.path, () =>
      restoreArchivedWorktree(services, serverId, checkout.projectId, checkout.path)
    )
    restoredFiles = restoredFiles && restored.restoredFiles
  }
  return restoredFiles
}

export const chatCheckoutsBeside = async (
  services: CodevisorServerServices,
  serverId: string,
  workspace: Workspace,
  chats?: ReadonlyArray<SessionSummary>
): Promise<ReadonlyArray<Checkout>> => {
  const held = chats ?? (await run(services.db.listSessions)).filter(isIn(workspace))
  const ids = new Set(
    held.flatMap((chat) => (chat.checkoutId === undefined ? [] : [chat.checkoutId]))
  )
  return (await run(services.db.listCheckouts)).filter(
    (checkout) =>
      ids.has(checkout.id) &&
      checkout.serverId === serverId &&
      checkout.worktreeName !== undefined &&
      checkout.path !== workspace.rootDirectory
  )
}

const isIn =
  (workspace: Workspace) =>
  (chat: SessionSummary): boolean =>
    chat.workspaceId?.toLowerCase() === workspace.id.toLowerCase()

interface RestoredWorktree {
  readonly restoredFiles: boolean
  readonly renamedTo?: string
}

const restoreArchivedWorktree = async (
  services: CodevisorServerServices,
  serverId: string,
  projectId: string,
  path: string
): Promise<RestoredWorktree> => {
  const worktreeName = worktreeNameAt(projectId, path)
  if (worktreeName === undefined) return { restoredFiles: true }
  const archived = await run(services.db.findArchivedWorktree(projectId, serverId, worktreeName))
  if (archived === undefined) {
    const existing = (await run(services.db.listWorktrees(projectId))).find(
      (candidate) => candidate.serverId === serverId && candidate.name === worktreeName
    )
    return { restoredFiles: existing !== undefined }
  }

  const project = await getProjectOrFail(services.db, projectId)
  const location = localLocationOrFail(serverId, project)
  const environment = await (services.resolveGitEnvironment?.(location.folderPath) ??
    Promise.resolve(process.env))
  const taken = new Set(
    (await run(services.db.listWorktrees(projectId)))
      .filter((candidate) => candidate.serverId === serverId)
      .map((candidate) => candidate.name)
  )
  const restored = await restoreWorktree({
    repoDir: location.folderPath,
    worktreePathFor: (name) => worktreePathBeside(projectId, path, name),
    originalName: archived.originalName,
    parentSha: archived.parentSha,
    snapshotRef: archived.snapshotRef,
    takenNames: taken,
    env: environment
  })
  await run(services.db.createWorktree(projectId, restored.name, restored.branch, archived.id))
  await run(services.db.deleteArchivedWorktree(archived.id))
  if (restored.restoredFromSnapshot) {
    await deleteSnapshot(location.folderPath, archived.id, environment)
  }
  if (restored.name === worktreeName) return { restoredFiles: restored.restoredFromSnapshot }

  for (const session of await run(services.db.listSessions)) {
    if (session.projectId !== projectId || session.worktreeName !== worktreeName) continue
    await run(services.db.updateSession(session.id, { worktreeName: restored.name }))
  }
  return { restoredFiles: restored.restoredFromSnapshot, renamedTo: restored.name }
}

export interface WorkspaceGitCheckout {
  readonly directory: string
  readonly branch?: string
  readonly ownedBranch?: OwnedBranch
}

export const workspaceGitCheckout = async (
  services: CodevisorServerServices,
  serverId: string,
  workspace: Workspace
): Promise<WorkspaceGitCheckout | undefined> => {
  let found: Awaited<ReturnType<typeof findArchivedWorktreeFor>>
  if (workspace.isArchived) found = await findArchivedWorktreeFor(services, serverId, workspace)
  if (found?.archived !== undefined) {
    const project = await getProjectOrFail(services.db, workspace.projectId)
    return {
      directory: localLocationOrFail(serverId, project).folderPath,
      branch: found.archived.branch
    }
  }
  const directory = existingDirectory(workspace.rootDirectory ?? null)
  if (directory === undefined) return undefined

  const ownedBranch = await workspaceOwnedBranch(services, workspace)
  return ownedBranch === undefined ? { directory } : { directory, ownedBranch }
}

const findArchivedWorktreeFor = async (
  services: CodevisorServerServices,
  serverId: string,
  workspace: Workspace
): Promise<
  | {
      readonly rootDirectory: string
      readonly worktreeName: string
      readonly archived: ArchivedWorktree | undefined
    }
  | undefined
> => {
  const rootDirectory = workspace.rootDirectory
  if (rootDirectory === undefined) return undefined
  const worktreeName = worktreeNameAt(workspace.projectId, rootDirectory)
  if (worktreeName === undefined) return undefined
  const archived = await run(
    services.db.findArchivedWorktree(workspace.projectId, serverId, worktreeName)
  )
  return { rootDirectory, worktreeName, archived }
}
