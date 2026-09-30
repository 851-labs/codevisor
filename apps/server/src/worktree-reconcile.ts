import { existsSync } from "node:fs"

import type { Project } from "@codevisor/api"
import {
  deleteSnapshot,
  listSnapshotRefWorktreeIds,
  pruneWorktreeRegistrations,
  releaseBranch,
  removeArchivedWorktreeFiles
} from "@codevisor/worktrees"

import { archiveJobs, enqueueWorkspaceArchive } from "./archive-jobs.js"
import type {
  CodevisorServerConfig,
  CodevisorServerServices,
  EventFanout
} from "./server-context-types.js"
import { localLocationOrFail, run } from "./server-http.js"
import { worktreeTrashRoot } from "./server-workspace-effects.js"

/// Boot housekeeping for worktree archives.
///
/// Archiving destroys files, and nothing in a filesystem is transactional with
/// SQLite. Rather than pretend otherwise, the archive path records its
/// intention first and this pass converges whatever the last run left behind:
///
///  - `pending` archives finish their file removal,
///  - archived workspaces whose teardown never ran (the server stopped
///    between answering the archive and running its job) are archived now,
///  - `worktrees` rows whose directory is gone stop occupying their name,
///  - snapshot refs with no row are deleted, because nothing can ever restore
///    them and they pin their objects against `git gc` forever.
///
/// Every step is best effort. This runs off the boot path and must never fail
/// startup: a repository that is missing, unreadable, or busy is simply left
/// for the next boot.

const repoDirFor = async (
  services: CodevisorServerServices,
  serverId: string,
  projectId: string
): Promise<string | undefined> => {
  try {
    const project = (await run(services.db.listProjects)).find(
      (candidate) => candidate.id.toLowerCase() === projectId.toLowerCase()
    )
    /* v8 ignore next -- unreachable: archived_worktrees cascades with its
       project, and the other caller iterates the list it just read. */
    if (project === undefined) return undefined
    return localLocationOrFail(serverId, project).folderPath
  } catch {
    return undefined
  }
}

/// Finishes archives interrupted between recording the snapshot and deleting
/// the files. Re-running the removal is safe: the snapshot already holds the
/// contents, and a path that is already gone counts as removed. The branch is
/// released either way, since an archive interrupted after the files went but
/// before the branch did would otherwise keep the name taken forever.
const finishPendingArchives = async (
  services: CodevisorServerServices,
  serverId: string
): Promise<void> => {
  const environment = await (services.resolveGitEnvironment?.() ?? Promise.resolve(process.env))
  const pending = (
    await Promise.all(
      (await run(services.db.listProjects)).map((project) =>
        run(services.db.listArchivedWorktrees(project.id))
      )
    )
  )
    .flat()
    .filter((archived) => archived.state === "pending")
  for (const archived of pending) {
    if (archived.serverId !== serverId) continue
    const repoDir = await repoDirFor(services, serverId, archived.projectId)
    if (repoDir === undefined) continue
    const worktree = (await run(services.db.listWorktrees(archived.projectId))).find(
      (candidate) => candidate.id.toLowerCase() === archived.id.toLowerCase()
    )
    try {
      if (worktree === undefined) {
        // Without the row the path is unknown, and the name may already be
        // reused, so only the git bookkeeping is finished.
        await pruneWorktreeRegistrations(repoDir, environment)
        await releaseBranch(repoDir, archived.branch, environment)
      } else {
        const trashed = await removeArchivedWorktreeFiles(repoDir, worktree.path, archived.branch, {
          trashRoot: worktreeTrashRoot(),
          worktreeId: archived.id,
          env: environment
        })
        archiveJobs(services).track(trashed.purged)
      }
      await run(services.db.createArchivedWorktree({ ...archived, state: "complete" }))
      if (worktree !== undefined) await run(services.db.deleteWorktree(worktree.id))
    } catch {
      // Leave the row pending; the next boot tries again.
    }
  }
}

/// Archives workspaces that were marked archived but whose worktree was never
/// torn down: a `worktrees` row still names their directory. The archive
/// request answers before its teardown job runs, so a server stopped in
/// between leaves this; so does a teardown that failed.
///
/// This runs after the pending-archive pass, so a row still here is one that
/// pass could not finish either. Archiving it again is safe: the job
/// re-snapshots the same files (the snapshot ref is overwritten, not
/// duplicated), and a directory that is already gone fails the snapshot
/// before anything is written.
const archiveStrandedWorkspaces = async (
  services: CodevisorServerServices,
  fanout: EventFanout,
  config: CodevisorServerConfig
): Promise<void> => {
  for (const workspace of await run(services.db.listWorkspaces)) {
    if (!workspace.isArchived || workspace.rootDirectory === undefined) continue
    const stranded = (await run(services.db.listWorktrees(workspace.projectId))).some(
      (candidate) => candidate.serverId === config.id && candidate.path === workspace.rootDirectory
    )
    if (stranded) await enqueueWorkspaceArchive(services, fanout, config, workspace)
  }
}

/// Drops `worktrees` rows whose directory no longer exists. A stale row keeps
/// its (finite) name reserved and makes restore report success for a workspace
/// whose files are gone.
const dropVanishedWorktrees = async (
  services: CodevisorServerServices,
  serverId: string
): Promise<void> => {
  const archivedIds = new Set<string>()
  const projects = await run(services.db.listProjects)
  for (const project of projects) {
    for (const archived of await run(services.db.listArchivedWorktrees(project.id))) {
      archivedIds.add(archived.id.toLowerCase())
    }
    for (const worktree of await run(services.db.listWorktrees(project.id))) {
      if (worktree.serverId !== serverId) continue
      if (existsSync(worktree.path)) continue
      // An archive in flight owns this row; leave it to the pass above.
      if (archivedIds.has(worktree.id.toLowerCase())) continue
      await run(services.db.deleteWorktree(worktree.id))
    }
  }
}

/// Deletes snapshot refs no `archived_worktrees` row names. These are created
/// when an archive is interrupted before its row is written; they are
/// unreachable by restore and immune to ordinary garbage collection.
const pruneOrphanSnapshots = async (
  services: CodevisorServerServices,
  serverId: string
): Promise<void> => {
  const environment = await (services.resolveGitEnvironment?.() ?? Promise.resolve(process.env))
  for (const project of await run(services.db.listProjects)) {
    const repoDir = await repoDirFor(services, serverId, project.id)
    if (repoDir === undefined) continue
    const known = new Set(
      (await run(services.db.listArchivedWorktrees(project.id))).map((archived) =>
        archived.id.toLowerCase()
      )
    )
    await pruneWorktreeRegistrations(repoDir, environment)
    for (const worktreeId of await listSnapshotRefWorktreeIds(repoDir, environment)) {
      if (known.has(worktreeId.toLowerCase())) continue
      await deleteSnapshot(repoDir, worktreeId, environment)
    }
  }
}

export const reconcileWorktreeArchives = async (
  services: CodevisorServerServices,
  fanout: EventFanout,
  config: CodevisorServerConfig
): Promise<void> => {
  await finishPendingArchives(services, config.id)
  await dropVanishedWorktrees(services, config.id)
  await archiveStrandedWorkspaces(services, fanout, config)
  await pruneOrphanSnapshots(services, config.id)
}

/// Removes every worktree, branch and snapshot a project owns on this server.
///
/// Project deletion is permanent by design, so this is the one path that
/// discards snapshots outright rather than preserving them. Row deletion
/// cascades in SQLite; none of this does.
export const discardProjectWorktrees = async (
  services: CodevisorServerServices,
  serverId: string,
  project: Project
): Promise<void> => {
  const location = project.locations.find((candidate) => candidate.serverId === serverId)
  if (location === undefined) return
  const environment = await (services.resolveGitEnvironment?.() ?? Promise.resolve(process.env))
  for (const worktree of await run(services.db.listWorktrees(project.id))) {
    if (worktree.serverId !== serverId) continue
    try {
      const trashed = await removeArchivedWorktreeFiles(
        location.folderPath,
        worktree.path,
        worktree.branch,
        { trashRoot: worktreeTrashRoot(), worktreeId: worktree.id, env: environment }
      )
      archiveJobs(services).track(trashed.purged)
    } catch {
      // Keep going: one stubborn worktree must not strand the others.
    }
  }
  for (const archived of await run(services.db.listArchivedWorktrees(project.id))) {
    if (archived.serverId !== serverId) continue
    await deleteSnapshot(location.folderPath, archived.id, environment)
  }
  await pruneWorktreeRegistrations(location.folderPath, environment)
}
