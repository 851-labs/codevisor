import type { ArchivedWorktree, SessionSummary, SessionUpdateGate, Workspace } from "@codevisor/api"
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
  session: Pick<SessionSummary, "workspaceId">
): Promise<boolean> => {
  const workspaceId = session.workspaceId
  if (workspaceId === undefined) return false
  return (await run(services.db.listWorkspaces)).some(
    (workspace) => workspace.id.toLowerCase() === workspaceId.toLowerCase() && workspace.isArchived
  )
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

export const makeTurnState = () => ({
  activePromptSessions: new Set<string>(),
  promptTurnReleases: new Map<string, () => void>(),
  activeTurnSessions: new Set<string>(),
  restartHeldSessions: new Map<string, SessionUpdateGate>(),
  heldTurnEnds: new Set<string>()
})

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

const directoryStillInUse = async (
  services: CodevisorServerServices,
  workspace: Workspace
): Promise<boolean> =>
  (await run(services.db.listWorkspaces)).some(
    (candidate) =>
      candidate.id.toLowerCase() !== workspace.id.toLowerCase() &&
      candidate.rootDirectory !== undefined &&
      candidate.rootDirectory === workspace.rootDirectory &&
      !candidate.isArchived
  )

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
  if (await directoryStillInUse(services, workspace)) return nothingArchived
  const worktree = (await run(services.db.listWorktrees(workspace.projectId))).find(
    (candidate) => candidate.serverId === serverId && candidate.path === rootDirectory
  )
  if (worktree === undefined) return nothingArchived

  const project = await getProjectOrFail(services.db, workspace.projectId)
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

export interface RestoredWorkspace {
  readonly workspace: Workspace
  readonly restoredFiles: boolean
}

export const restoreWorkspaceWorktree = async (
  services: CodevisorServerServices,
  serverId: string,
  workspace: Workspace
): Promise<RestoredWorkspace> =>
  withWorktreeLifecycle(services, workspace.rootDirectory ?? workspace.id, async () => {
    const found = await findArchivedWorktreeFor(services, serverId, workspace)
    if (found === undefined) return { workspace, restoredFiles: true }
    const { rootDirectory, worktreeName, archived } = found
    if (archived === undefined) {
      const existing = (await run(services.db.listWorktrees(workspace.projectId))).find(
        (candidate) => candidate.serverId === serverId && candidate.name === worktreeName
      )
      return { workspace, restoredFiles: existing !== undefined }
    }

    const project = await getProjectOrFail(services.db, workspace.projectId)
    const location = localLocationOrFail(serverId, project)
    const environment = await (services.resolveGitEnvironment?.(location.folderPath) ??
      Promise.resolve(process.env))
    const taken = new Set(
      (await run(services.db.listWorktrees(workspace.projectId)))
        .filter((candidate) => candidate.serverId === serverId)
        .map((candidate) => candidate.name)
    )
    const restored = await restoreWorktree({
      repoDir: location.folderPath,
      worktreePathFor: (name) => worktreePathBeside(workspace.projectId, rootDirectory, name),
      originalName: archived.originalName,
      parentSha: archived.parentSha,
      snapshotRef: archived.snapshotRef,
      takenNames: taken,
      env: environment
    })
    await run(
      services.db.createWorktree(workspace.projectId, restored.name, restored.branch, archived.id)
    )
    await run(services.db.deleteArchivedWorktree(archived.id))
    if (restored.restoredFromSnapshot) {
      await deleteSnapshot(location.folderPath, archived.id, environment)
    }

    let updated = workspace
    if (restored.name !== worktreeName) {
      const path = worktreePath(workspace.projectId, restored.name)
      updated = await run(services.db.updateWorkspace(workspace.id, { rootDirectory: path }))
      for (const session of await run(services.db.listSessions)) {
        if (session.projectId !== workspace.projectId || session.worktreeName !== worktreeName) {
          continue
        }
        await run(services.db.updateSession(session.id, { worktreeName: restored.name }))
      }
    }
    return { workspace: updated, restoredFiles: restored.restoredFromSnapshot }
  })

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
