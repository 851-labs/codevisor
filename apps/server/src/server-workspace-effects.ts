import { join } from "node:path"

import type { SessionSummary, Workspace } from "@codevisor/api"
import { isoTimestamp } from "@codevisor/api"
import { worktreePath, worktreesRoot } from "@codevisor/db"
import {
  deleteSnapshot,
  removeArchivedWorktreeFiles,
  restoreWorktree,
  snapshotWorktree,
  sweepWorktreeTrash
} from "@codevisor/worktrees"

import type { CodevisorServerServices, RouteState } from "./server-context-types.js"
import { getProjectOrFail, localLocationOrFail, run, swallowError } from "./server-http.js"
import { settleCleanup, workspaceTerminalKeys } from "./workspace-runtime.js"
import { withWorktreeLifecycle } from "./worktree-lifecycle.js"

/// Removed worktrees are renamed into this folder and deleted in the
/// background. It sits beside the worktrees so the rename never crosses a
/// volume.
export const worktreeTrashRoot = (): string => join(worktreesRoot(), ".trash")

/// Finishes deleting worktree files a previous run moved to the trash but
/// didn't get to delete. Runs at background priority, so boot never waits on
/// it and it never competes with the user's work.
export const sweepTrashedWorktrees = (): Promise<void> => sweepWorktreeTrash(worktreeTrashRoot())

/// Workspace archive side effects: retiring runtimes and reclaiming the
/// worktree the workspace owns.
///
/// The workspace is the only thing that carries archive state. A chat is
/// merely open or closed (it has a `workspace_panes` row or it does not), so
/// nothing here reads or writes per-session archive flags.

/// Whether the chat's workspace is archived. Chats have no archive state of
/// their own, so every "is this chat still live?" guard asks its workspace.
/// A chat with no workspace (created before workspaces existed, or detached)
/// is never archived.
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

/// Stops one chat's agent, terminals, and MCP session.
export const retireSessionRuntime = async (
  services: CodevisorServerServices,
  session: SessionSummary
): Promise<void> => {
  /* v8 ignore next -- SessionSummary types agentSessionId as optional, but created sessions always carry one. */
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
  // Always close the agent, even if a terminal failed, but keep the files
  // when cleanup cannot establish that all owned processes have stopped.
  await settleCleanup([
    ...(agentSessionId.length === 0
      ? []
      : [run(services.agents.closeAgentSession(agentSessionId))]),
    services.mcp?.closeSession(session.id) ?? Promise.resolve()
  ])
  if (failure !== undefined) throw failure
}

/// The turn-liveness state a retire clears.
export type RetiredTurnState = Pick<
  RouteState,
  "activeTurnSessions" | "promptTurnReleases" | "turnHeldSessions"
>

/// Forgets a retired chat's live turn. Its runtime is being closed, so the
/// turn is over as far as updates are concerned — whether or not the harness
/// ever reports it ended. Without this, archiving a working chat (or one
/// waiting on a question) left its turn counted as live: a harness update
/// armed behind it never ran, and a server update waited out its full drain.
export const forgetRetiredSessionTurn = (turns: RetiredTurnState, sessionId: string): void => {
  turns.promptTurnReleases.get(sessionId)?.()
  turns.activeTurnSessions.delete(sessionId)
  turns.turnHeldSessions.delete(sessionId)
}

/// Drops a just-counted turn if its chat is already archived. An archived
/// chat's runtime is on its way out, so its turns never hold an update — but
/// a harness can still start one after the archive (a background task
/// finishing wakes the agent), and that turn's end event never comes.
///
/// Called right after the turn is counted, so it cannot race the archive:
/// either this read sees the archive, or the archive commits later and its
/// own `forgetRetiredSessionTurn` sweep clears the turn.
export const forgetTurnIfArchived = async (
  services: CodevisorServerServices,
  turns: RetiredTurnState,
  sessionId: string
): Promise<void> => {
  const session = await run(services.db.getSessionSummary(sessionId)).catch(swallowError)
  if (session === undefined || !(await sessionIsArchived(services, session))) return
  forgetRetiredSessionTurn(turns, sessionId)
}

/// Everything running on a workspace's behalf, read while the workspace and
/// its panes still exist. Retirement runs later, after a delete may already
/// have detached the chats and dropped the panes.
export interface WorkspaceRuntime {
  readonly sessions: ReadonlyArray<SessionSummary>
  readonly terminalKeys: ReadonlyArray<string>
}

/// Its chats' turns end here, when the archive is recorded, rather than when
/// the queued teardown gets to them: updates must not wait behind a turn whose
/// runtime is already on its way out.
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

/// Stops every process a workspace owns: its chats' agents and terminals, plus
/// terminals opened in the workspace without a chat.
export const retireWorkspaceRuntime = async (
  services: CodevisorServerServices,
  runtime: WorkspaceRuntime
): Promise<void> => {
  await settleCleanup([
    ...runtime.terminalKeys.map((key) => run(services.terminal.closeTerminalForSession(key))),
    ...runtime.sessions.map((session) => retireSessionRuntime(services, session))
  ])
}

/// Whether any OTHER workspace still needs the directory. A workspace anchored
/// at the project root shares its path with the repository itself and never
/// owns a `worktrees` row, so it can never reach the removal below.
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
  readonly ignoredPaths: ReadonlyArray<string>
  readonly purged: Promise<void>
}

const nothingArchived: ArchivedWorkspaceWorktree = { ignoredPaths: [], purged: Promise.resolve() }

/// Retires an archived workspace's git worktree.
///
/// The files are captured as a snapshot commit first, so archiving is lossless:
/// uncommitted and untracked work survives in `refs/codevisor/archived/<id>`.
/// The `archived_worktrees` row is written BEFORE anything is deleted, so an
/// interruption leaves a `pending` row the boot reconciler finishes instead of
/// a snapshot nothing references and a `worktrees` row pointing at a directory
/// that is already gone.
///
/// The caller must hold the worktree lifecycle lock for the workspace.
///
/// Returns the gitignored paths that were deliberately not snapshotted, and a
/// promise that settles once the removed files are deleted from the trash.
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
  // No `worktrees` row means this is the user's own project folder, which we
  // must never touch.
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
  // Same record, now that the files really are gone. `createArchivedWorktree`
  // upserts on id, so this is the completion write.
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
  return { ignoredPaths: snapshot.ignoredPaths, purged: trashed.purged }
}

/// Rebuilds an unarchived workspace's worktree from its snapshot.
///
/// Restore may hand back a DIFFERENT worktree name than the workspace had: the
/// original is freed at archive time and can legitimately be claimed while the
/// workspace sits archived. The workspace's `rootDirectory` and every member
/// chat's `worktree_name` are rewritten to match.
export const restoreWorkspaceWorktree = async (
  services: CodevisorServerServices,
  serverId: string,
  workspace: Workspace
): Promise<{ readonly workspace: Workspace; readonly restoredFiles: boolean }> =>
  withWorktreeLifecycle(services, workspace.rootDirectory ?? workspace.id, async () => {
    const rootDirectory = workspace.rootDirectory
    if (rootDirectory === undefined) return { workspace, restoredFiles: true }
    const worktreeName = archivedNameFor(workspace.projectId, rootDirectory)
    if (worktreeName === undefined) return { workspace, restoredFiles: true }

    // Our own snapshot wins over any worktree that merely shares the name.
    // Archiving frees the name, so an unrelated worktree can be created under
    // it in the meantime; treating that as "already live" would silently point
    // the workspace at a stranger's files and strand the snapshot forever.
    const archived = await run(
      services.db.findArchivedWorktree(workspace.projectId, serverId, worktreeName)
    )
    if (archived === undefined) {
      const existing = (await run(services.db.listWorktrees(workspace.projectId))).find(
        (candidate) => candidate.serverId === serverId && candidate.name === worktreeName
      )
      return { workspace, restoredFiles: existing !== undefined }
    }

    const project = await getProjectOrFail(services.db, workspace.projectId)
    const location = localLocationOrFail(serverId, project)
    const environment = await (services.resolveGitEnvironment?.() ?? Promise.resolve(process.env))
    const taken = new Set(
      (await run(services.db.listWorktrees(workspace.projectId)))
        .filter((candidate) => candidate.serverId === serverId)
        .map((candidate) => candidate.name)
    )
    const restored = await restoreWorktree({
      repoDir: location.folderPath,
      worktreePathFor: (name) => worktreePath(workspace.projectId, name),
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
    // Only drop the snapshot once its contents are actually on disk. Deleting
    // it after a failed apply would destroy the user's only copy of the
    // uncommitted work the snapshot exists to protect.
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

/// A worktree-backed workspace's directory is always `worktreePath(project,
/// name)`, so the name is recoverable from the path alone — which is all an
/// archived workspace still carries once its `worktrees` row is gone.
const archivedNameFor = (projectId: string, rootDirectory: string): string | undefined => {
  const separator = rootDirectory.lastIndexOf("/")
  if (separator < 0) return undefined
  const name = rootDirectory.slice(separator + 1)
  return worktreePath(projectId, name) === rootDirectory ? name : undefined
}
