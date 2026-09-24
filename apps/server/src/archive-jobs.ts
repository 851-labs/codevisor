import type { Workspace } from "@codevisor/api"

import type {
  CodevisorServerConfig,
  CodevisorServerServices,
  EventFanout
} from "./server-context-types.js"
import { appendAndPublish, run, swallowError } from "./server-http.js"
import {
  archiveWorkspaceWorktree,
  captureWorkspaceRuntime,
  restoreWorkspaceWorktree,
  retireWorkspaceRuntime,
  type RetiredTurnState,
  type WorkspaceRuntime
} from "./server-workspace-effects.js"
import { withWorktreeLifecycle } from "./worktree-lifecycle.js"

/// Archiving a workspace stops its processes, snapshots its worktree, and
/// removes the files. That takes seconds to minutes, and clients send their
/// requests one at a time, so doing it inside the request stalled every later
/// request from that client. The request now answers once the archive is
/// recorded, and the teardown runs here.
///
/// Jobs run one at a time per server. Archiving several workspaces at once is
/// exactly when the machine is busiest, and running their snapshots and
/// removals side by side would only make each of them slower.
export interface ArchiveJobs {
  /// Counts background work that runs outside the queue, such as deleting
  /// trashed files, towards `idle`.
  readonly track: (work: Promise<void>) => void
  /// Resolves once every job enqueued so far, and all tracked work, has
  /// finished. Tests wait on this instead of polling the filesystem.
  readonly idle: () => Promise<void>
  /// Resolves once every job enqueued so far has finished, without waiting on
  /// tracked deletions. Shutdown waits on this: a background delete can take
  /// minutes, and the next boot sweeps whatever it left.
  readonly jobsFinished: () => Promise<void>
}

interface ArchiveJobQueue extends ArchiveJobs {
  readonly enqueue: (job: () => Promise<void>) => Promise<void>
}

const queues = new WeakMap<CodevisorServerServices, ArchiveJobQueue>()

const makeQueue = (): ArchiveJobQueue => {
  const outstanding = new Set<Promise<void>>()
  let tail: Promise<void> = Promise.resolve()
  const track = (work: Promise<void>): void => {
    // A failed job leaves recoverable state (see the boot reconcile), so its
    // error has nowhere useful to go once the request has been answered.
    const settled = work.then(swallowError, swallowError)
    outstanding.add(settled)
    void settled.then(() => outstanding.delete(settled))
  }
  return {
    enqueue: (job) => {
      tail = tail.then(job).then(swallowError, swallowError)
      track(tail)
      return tail
    },
    track,
    jobsFinished: () => tail,
    idle: async () => {
      while (outstanding.size > 0) await Promise.all(outstanding)
    }
  }
}

const queueFor = (services: CodevisorServerServices): ArchiveJobQueue => {
  let queue = queues.get(services)
  if (queue === undefined) {
    queue = makeQueue()
    queues.set(services, queue)
  }
  return queue
}

export const archiveJobs = (services: CodevisorServerServices): ArchiveJobs => queueFor(services)

const findWorkspace = async (
  services: CodevisorServerServices,
  workspaceId: string
): Promise<Workspace | undefined> =>
  (await run(services.db.listWorkspaces)).find(
    (candidate) => candidate.id.toLowerCase() === workspaceId.toLowerCase()
  )

/// Queues the teardown of an archived (or deleted) workspace. `runtime` is
/// omitted at boot, when no process from the previous run is still alive.
///
/// The job re-reads the workspace under the worktree lifecycle lock before it
/// touches anything: an unarchive that lands first owns the worktree, so the
/// job does nothing. An unarchive that lands after the job starts waits on the
/// same lock and then restores from the snapshot the job made.
///
/// Settles when the job finishes; never rejects.
export const enqueueWorkspaceArchive = (
  services: CodevisorServerServices,
  fanout: EventFanout,
  config: CodevisorServerConfig,
  workspace: Workspace,
  runtime?: WorkspaceRuntime
): Promise<void> => {
  const queue = queueFor(services)
  return queue.enqueue(() =>
    withWorktreeLifecycle(services, workspace.rootDirectory ?? workspace.id, async () => {
      if ((await findWorkspace(services, workspace.id))?.isArchived === false) return
      // Keep the files when cleanup cannot establish that every owned process
      // has stopped; a later archive or the boot reconcile retries.
      if (runtime !== undefined) await retireWorkspaceRuntime(services, runtime)
      const archived = await archiveWorkspaceWorktree(services, config.id, workspace)
      queue.track(archived.purged)
      if (archived.ignoredPaths.length === 0) return
      // Read again: the workspace may have been deleted while this ran, and a
      // deleted workspace has already been announced as gone. An update now
      // would bring it back on clients.
      const current = await findWorkspace(services, workspace.id)
      if (current !== undefined) {
        // Gitignored files are deliberately not snapshotted (they can hold
        // secrets and are usually regenerable). Tell the client which ones went
        // away with the worktree rather than losing them silently.
        await appendAndPublish(services.db, fanout, "workspace.updated", current.id, {
          ...current,
          archiveDroppedIgnoredPaths: archived.ignoredPaths
        })
      }
    })
  )
}

/// Applies a workspace's archive transition.
///
/// The event is published first so a client never waits on a process that
/// refuses to die, and a cleanup failure can never swallow the state change
/// the database already committed. Archiving then returns without waiting for
/// the teardown (see `enqueueWorkspaceArchive`); teardown failures leave the
/// worktree reclaimable by the boot reconciler or a repeat archive.
///
/// Unarchiving still restores inline, because the client needs the restored
/// directory before it can use the workspace.
export const applyWorkspaceArchiveEffects = async (
  services: CodevisorServerServices,
  fanout: EventFanout,
  config: CodevisorServerConfig,
  turns: RetiredTurnState,
  workspace: Workspace,
  wasArchived: boolean
): Promise<Workspace> => {
  await appendAndPublish(services.db, fanout, "workspace.updated", workspace.id, workspace)
  if (workspace.isArchived === wasArchived) return workspace

  if (workspace.isArchived) {
    const runtime = await captureWorkspaceRuntime(services, turns, workspace)
    void enqueueWorkspaceArchive(services, fanout, config, workspace, runtime)
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
