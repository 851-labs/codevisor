import type { SessionSummary, Workspace } from "@codevisor/api"
import { isoTimestamp } from "@codevisor/api"
import { worktreePath } from "@codevisor/db"
import {
  deleteSnapshot,
  removeArchivedWorktreeFiles,
  removeWorktree,
  restoreWorktree,
  snapshotWorktree
} from "@codevisor/worktrees"

import { EventFanout } from "./server-context-types.js"
import type { CodevisorServerConfig, CodevisorServerServices } from "./server-context-types.js"
import { appendAndPublish, getProjectOrFail, localLocationOrFail, run } from "./server-http.js"
import { closeWorkspaceTerminals, settleCleanup } from "./workspace-runtime.js"
import { withWorktreeLifecycle } from "./worktree-lifecycle.js"

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

/// Stops every process a workspace owns: its chats' agents and terminals, plus
/// terminals opened in the workspace without a chat.
export const retireWorkspaceRuntime = async (
  services: CodevisorServerServices,
  workspace: Workspace
): Promise<void> => {
  const sessions = (await run(services.db.listSessions)).filter(
    (session) => session.workspaceId?.toLowerCase() === workspace.id.toLowerCase()
  )
  await settleCleanup([
    closeWorkspaceTerminals(services, [workspace.id]),
    ...sessions.map((session) => retireSessionRuntime(services, session))
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

/// Retires an archived workspace's git worktree.
///
/// The files are captured as a snapshot commit first, so archiving is lossless:
/// uncommitted and untracked work survives in `refs/codevisor/archived/<id>`.
/// The `archived_worktrees` row is written BEFORE anything is deleted, so an
/// interruption leaves a `pending` row the boot reconciler finishes instead of
/// a snapshot nothing references and a `worktrees` row pointing at a directory
/// that is already gone.
///
/// Returns the gitignored paths that were deliberately not snapshotted.
export const archiveWorkspaceWorktree = async (
  services: CodevisorServerServices,
  serverId: string,
  workspace: Workspace
): Promise<ReadonlyArray<string>> =>
  withWorktreeLifecycle(services, workspace.rootDirectory ?? workspace.id, async () => {
    const rootDirectory = workspace.rootDirectory
    if (rootDirectory === undefined) return []
    if (await directoryStillInUse(services, workspace)) return []
    const worktree = (await run(services.db.listWorktrees(workspace.projectId))).find(
      (candidate) => candidate.serverId === serverId && candidate.path === rootDirectory
    )
    // No `worktrees` row means this is the user's own project folder, which we
    // must never touch.
    if (worktree === undefined) return []

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
    await removeArchivedWorktreeFiles(
      location.folderPath,
      worktree.path,
      worktree.branch,
      removeWorktree,
      environment
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
    return snapshot.ignoredPaths
  })

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

/// Applies a workspace's archive transition.
///
/// The event is published BEFORE any teardown so a client never waits on a
/// process that refuses to die, and a cleanup failure can never swallow the
/// state change the database already committed. Teardown failures leave the
/// archive recorded and the worktree reclaimable by the boot reconciler or a
/// repeat archive, rather than failing the request and stranding the client.
export const applyWorkspaceArchiveEffects = async (
  services: CodevisorServerServices,
  fanout: EventFanout,
  config: CodevisorServerConfig,
  workspace: Workspace,
  wasArchived: boolean
): Promise<Workspace> => {
  await appendAndPublish(services.db, fanout, "workspace.updated", workspace.id, workspace)
  if (workspace.isArchived === wasArchived) return workspace

  if (workspace.isArchived) {
    await retireWorkspaceRuntime(services, workspace)
    const ignored = await archiveWorkspaceWorktree(services, config.id, workspace)
    if (ignored.length > 0) {
      // Gitignored files are deliberately not snapshotted (they can hold
      // secrets and are usually regenerable). Tell the client which ones went
      // away with the worktree rather than losing them silently.
      await appendAndPublish(services.db, fanout, "workspace.updated", workspace.id, {
        ...workspace,
        archiveDroppedIgnoredPaths: ignored
      })
    }
    return workspace
  }

  const restored = await restoreWorkspaceWorktree(services, config.id, workspace)
  if (!restored.restoredFiles) {
    await appendAndPublish(services.db, fanout, "workspace.updated", workspace.id, {
      ...restored.workspace,
      archiveRestoreIncomplete: true
    })
    return restored.workspace
  }
  // A restore that had to rename the worktree rewrote `rootDirectory`, so the
  // caller must answer with the new row rather than the one it wrote.
  if (restored.workspace !== workspace) {
    await appendAndPublish(
      services.db,
      fanout,
      "workspace.updated",
      workspace.id,
      restored.workspace
    )
  }
  return restored.workspace
}
