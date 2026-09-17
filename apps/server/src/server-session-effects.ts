import type { SessionSummary, Workspace } from "@codevisor/api"
import { isoTimestamp } from "@codevisor/api"
import { worktreePath } from "@codevisor/db"
import { archiveWorktreeFiles, deleteSnapshot, restoreWorktree } from "@codevisor/worktrees"
import { removeWorktree } from "@codevisor/worktrees"

import { EventFanout } from "./server-context-types.js"
import type { CodevisorServerConfig, CodevisorServerServices } from "./server-context-types.js"
import { getProjectOrFail, localLocationOrFail, appendAndPublish, run } from "./server-http.js"
import { closeWorkspaceTerminals, settleCleanup } from "./workspace-runtime.js"
import { withWorktreeLifecycle } from "./worktree-lifecycle.js"

/// Session lifecycle side effects: retiring runtimes, archiving and restoring
/// worktrees, and cascading archive/publish across related records.

export const archiveSessionRuntime = async (
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

/// Retires an archived session's git worktree once no other active session on
/// this server still relies on it. The files are captured as a snapshot commit
/// first, so archiving is lossless: uncommitted and untracked work survives in
/// `refs/codevisor/archived/<worktreeId>` and can be restored on unarchive.
///
/// The `worktrees` row and the branch are both dropped, which is what returns
/// the (finite) worktree name to the pool. The `archived_worktrees` record is
/// what restore navigates by.
///
/// Sessions in non-git projects carry no worktree name and return immediately:
/// their cwd is the user's own project folder, which we must never touch.
export const archiveSessionWorktree = async (
  services: CodevisorServerServices,
  serverId: string,
  session: SessionSummary
): Promise<ReadonlyArray<string>> =>
  withWorktreeLifecycle(services, `${session.projectId}:${session.worktreeName}`, async () => {
    const worktreeName = session.worktreeName
    if (worktreeName === undefined) {
      return []
    }
    const stillInUse = (await run(services.db.listSessions)).some(
      (candidate) =>
        !candidate.isArchived &&
        candidate.projectId === session.projectId &&
        candidate.worktreeName === worktreeName
    )
    if (stillInUse) {
      return []
    }
    const worktree = (await run(services.db.listWorktrees(session.projectId))).find(
      (candidate) => candidate.serverId === serverId && candidate.name === worktreeName
    )
    if (worktree === undefined) {
      return []
    }
    const workspaces = (await run(services.db.listWorkspaces)).filter(
      (workspace) =>
        workspace.projectId === session.projectId && workspace.rootDirectory === worktree.path
    )
    if (workspaces.some((workspace) => !workspace.isArchived)) return []
    // Individual chat archive requests race with workspace cascades. Capture
    // every archived sibling here as well, before touching their shared cwd.
    await settleCleanup([
      closeWorkspaceTerminals(
        services,
        workspaces.map((workspace) => workspace.id)
      ),
      ...(await run(services.db.listSessions))
        .filter(
          (candidate) =>
            candidate.isArchived &&
            candidate.projectId === session.projectId &&
            candidate.worktreeName === worktreeName
        )
        .map((candidate) => archiveSessionRuntime(services, candidate))
    ])
    const project = await getProjectOrFail(services.db, session.projectId)
    const location = localLocationOrFail(serverId, project)
    const environment = await (services.resolveGitEnvironment?.() ?? Promise.resolve(process.env))
    const snapshot = await archiveWorktreeFiles(
      location.folderPath,
      worktree.path,
      worktree.id,
      worktree.branch,
      removeWorktree,
      environment
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
        createdAt: isoTimestamp()
      })
    )
    await run(services.db.deleteWorktree(worktree.id))
    return snapshot.ignoredPaths
  })

/// Rebuilds an unarchived session's worktree from its snapshot.
///
/// Restore may hand back a DIFFERENT worktree name than the session had: the
/// original is freed at archive time and can legitimately be claimed while the
/// chat sits archived. The session's `worktree_name` is rewritten to match, as
/// is every other archived session that shared that worktree, so they all
/// still resolve to one directory if they are later restored too.
export const restoreSessionWorktree = async (
  services: CodevisorServerServices,
  serverId: string,
  session: SessionSummary
): Promise<{ readonly session: SessionSummary; readonly restoredFiles: boolean }> =>
  withWorktreeLifecycle(services, `${session.projectId}:${session.worktreeName}`, async () => {
    const worktreeName = session.worktreeName
    if (worktreeName === undefined) {
      return { session, restoredFiles: true }
    }
    // Our own snapshot wins over any worktree that merely shares the name.
    // Archiving frees the name, so an unrelated worktree can be created under
    // it in the meantime; treating that as "already live" would silently point
    // the chat at a stranger's files and strand the snapshot forever.
    const archived = await run(
      services.db.findArchivedWorktree(session.projectId, serverId, worktreeName)
    )
    if (archived === undefined) {
      // No snapshot of our own: either another session in this worktree was
      // unarchived first (reattach to it), or the archive predates snapshots,
      // in which case the chat still unarchives but its cwd may not exist.
      const existing = (await run(services.db.listWorktrees(session.projectId))).find(
        (candidate) => candidate.serverId === serverId && candidate.name === worktreeName
      )
      return { session, restoredFiles: existing !== undefined }
    }
    const project = await getProjectOrFail(services.db, session.projectId)
    const location = localLocationOrFail(serverId, project)
    const environment = await (services.resolveGitEnvironment?.() ?? Promise.resolve(process.env))
    const taken = new Set(
      (await run(services.db.listWorktrees(session.projectId)))
        .filter((candidate) => candidate.serverId === serverId)
        .map((candidate) => candidate.name)
    )
    const restored = await restoreWorktree({
      repoDir: location.folderPath,
      worktreePathFor: (name) => worktreePath(session.projectId, name),
      originalName: archived.originalName,
      parentSha: archived.parentSha,
      snapshotRef: archived.snapshotRef,
      takenNames: taken,
      env: environment
    })
    await run(
      services.db.createWorktree(session.projectId, restored.name, restored.branch, archived.id)
    )
    await run(services.db.deleteArchivedWorktree(archived.id))
    await deleteSnapshot(location.folderPath, archived.id, environment)

    let updated = session
    if (restored.name !== worktreeName) {
      for (const candidate of await run(services.db.listSessions)) {
        if (candidate.projectId !== session.projectId || candidate.worktreeName !== worktreeName) {
          continue
        }
        const next = await run(
          services.db.updateSession(candidate.id, { worktreeName: restored.name })
        )
        if (candidate.id === session.id) {
          updated = next
        }
      }
    }
    return { session: updated, restoredFiles: restored.restoredFromSnapshot }
  })

/// Fans out `workspace.updated` for workspaces a cascade archived or revived,
/// so a client's archived section stays in step without a full refetch.
export const publishChangedWorkspaces = async (
  services: CodevisorServerServices,
  fanout: EventFanout,
  before: ReadonlyArray<Workspace>
): Promise<void> => {
  const previous = new Map(before.map((workspace) => [workspace.id, workspace.isArchived]))
  for (const workspace of await run(services.db.listWorkspaces)) {
    if (previous.get(workspace.id) === workspace.isArchived) {
      continue
    }
    await appendAndPublish(services.db, fanout, "workspace.updated", workspace.id, workspace)
  }
}

/// Publishes archive events before cleanup so clients can hide rows promptly.
/// Stops every affected chat and workspace terminal before snapshotting shared
/// worktrees. Explicit workspace IDs also cover workspaces without chats and
/// allow an archive retry to finish cleanup after a previous failure.
export const applyCascadedSessionEffects = async (
  services: CodevisorServerServices,
  fanout: EventFanout,
  config: CodevisorServerConfig,
  before: ReadonlyArray<SessionSummary>,
  archivedWorkspaceIds: ReadonlyArray<string> = []
): Promise<void> => {
  const previous = new Map(before.map((session) => [session.id, session.isArchived]))
  const sessions = await run(services.db.listSessions)
  const changed = sessions.filter(
    (session) => previous.has(session.id) && previous.get(session.id) !== session.isArchived
  )
  const archived = sessions.filter(
    (session) =>
      session.isArchived &&
      (changed.includes(session) ||
        (session.workspaceId !== undefined && archivedWorkspaceIds.includes(session.workspaceId)))
  )
  for (const session of archived) {
    await appendAndPublish(services.db, fanout, "session.archived", session.id, session)
  }
  await settleCleanup([
    closeWorkspaceTerminals(services, archivedWorkspaceIds),
    ...archived.map((session) => archiveSessionRuntime(services, session))
  ])
  // Every chat and terminal stops before the first shared worktree is removed.
  for (const session of archived) await archiveSessionWorktree(services, config.id, session)
  for (const current of changed) {
    if (current.isArchived) continue
    const session = (await restoreSessionWorktree(services, config.id, current)).session
    await appendAndPublish(services.db, fanout, "session.unarchived", session.id, session)
  }
}
