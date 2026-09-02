import type { SessionSummary, Workspace } from "@codevisor/api"
import { isoTimestamp } from "@codevisor/api"
import { worktreePath } from "@codevisor/db"
import { archiveWorktreeFiles, deleteSnapshot, restoreWorktree } from "@codevisor/worktrees"
import { removeWorktree } from "@codevisor/worktrees"
import { EventFanout } from "./server-context-types.js"
import type { CodevisorServerConfig, CodevisorServerServices } from "./server-context-types.js"
import { getProjectOrFail, localLocationOrFail, appendAndPublish, run } from "./server-http.js"

/// Session lifecycle side effects: retiring runtimes, archiving and restoring
/// worktrees, and cascading archive/publish across related records.

export const archiveSessionRuntime = async (
  services: CodevisorServerServices,
  session: SessionSummary
): Promise<void> => {
  await services.mcp?.closeSession(session.id)
  /* v8 ignore next -- SessionSummary types agentSessionId as optional, but created sessions always carry one. */
  const agentSessionId = session.agentSessionId ?? ""
  if (agentSessionId.length === 0) {
    return
  }
  try {
    await run(services.agents.closeAgentSession(agentSessionId))
    await run(services.terminal.closeTerminalsForSessionPrefix(`${agentSessionId}:bg:`))
    /* v8 ignore next 3 -- best-effort: archiving must succeed even when the runtime is already gone. */
  } catch {
    // Best-effort.
  }
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
): Promise<ReadonlyArray<string>> => {
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
}

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
): Promise<{ readonly session: SessionSummary; readonly restoredFiles: boolean }> => {
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
}

/// Archiving a project or workspace flips its sessions' flags inside one
/// database transaction, but the runtime consequences live outside it: agent
/// processes to stop, background terminals to kill, worktrees to snapshot and
/// remove. This replays those effects for exactly the sessions whose archived
/// state actually changed, and fans out a per-session event so clients can
/// move the rows between sidebar sections.
///
/// Worktree bookkeeping falls out naturally: the cascade has already flagged
/// every session archived, so the first one reaching `archiveSessionWorktree`
/// finds no active user and takes the snapshot; the rest short-circuit.
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

export const applyCascadedSessionEffects = async (
  services: CodevisorServerServices,
  fanout: EventFanout,
  config: CodevisorServerConfig,
  before: ReadonlyArray<SessionSummary>
): Promise<void> => {
  const previous = new Map(before.map((session) => [session.id, session.isArchived]))
  for (const current of await run(services.db.listSessions)) {
    const wasArchived = previous.get(current.id)
    if (wasArchived === undefined || wasArchived === current.isArchived) {
      continue
    }
    let session = current
    if (session.isArchived) {
      await archiveSessionRuntime(services, session)
      await archiveSessionWorktree(services, config.id, session)
    } else {
      session = (await restoreSessionWorktree(services, config.id, session)).session
    }
    await appendAndPublish(
      services.db,
      fanout,
      session.isArchived ? "session.archived" : "session.unarchived",
      session.id,
      session
    )
  }
}
