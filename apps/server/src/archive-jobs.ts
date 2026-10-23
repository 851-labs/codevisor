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

export interface ArchiveJobs {
  readonly track: (work: Promise<void>) => void
  readonly idle: () => Promise<void>
  readonly jobsFinished: () => Promise<void>
}

interface ArchiveJobQueue extends ArchiveJobs {
  readonly enqueue: <A>(job: () => Promise<A>) => Promise<A>
}

const queues = new WeakMap<CodevisorServerServices, ArchiveJobQueue>()

const makeQueue = (): ArchiveJobQueue => {
  const outstanding = new Set<Promise<void>>()
  let tail: Promise<void> = Promise.resolve()
  const track = (work: Promise<void>): void => {
    const settled = work.then(swallowError, swallowError)
    outstanding.add(settled)
    void settled.then(() => outstanding.delete(settled))
  }
  return {
    enqueue: (job) => {
      const result = tail.then(job)
      tail = result.then(swallowError, swallowError)
      track(tail)
      return result
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

export const enqueueWorkspaceArchive = (
  services: CodevisorServerServices,
  fanout: EventFanout,
  config: CodevisorServerConfig,
  workspace: Workspace,
  runtime?: WorkspaceRuntime
): Promise<ReadonlyArray<string>> =>
  archiveWorkspaceAndWait(services, fanout, config, workspace, runtime).catch(
    (): ReadonlyArray<string> => []
  )

export const archiveWorkspaceAndWait = (
  services: CodevisorServerServices,
  fanout: EventFanout,
  config: CodevisorServerConfig,
  workspace: Workspace,
  runtime?: WorkspaceRuntime
): Promise<ReadonlyArray<string>> => {
  const queue = queueFor(services)
  return queue.enqueue(() =>
    withWorktreeLifecycle(services, workspace.rootDirectory ?? workspace.id, async () => {
      if ((await findWorkspace(services, workspace.id))?.isArchived === false) return []
      if (runtime !== undefined) await retireWorkspaceRuntime(services, runtime)
      const archived = await archiveWorkspaceWorktree(services, config.id, workspace)
      queue.track(archived.purged)
      await publishKeptArtifacts(services, fanout, workspace.id, archived.keptArtifacts)
      return archived.keptArtifacts
    })
  )
}

const publishKeptArtifacts = async (
  services: CodevisorServerServices,
  fanout: EventFanout,
  workspaceId: string,
  keptArtifacts: ReadonlyArray<string>
): Promise<void> => {
  if (keptArtifacts.length === 0) return
  const current = await findWorkspace(services, workspaceId)
  if (current === undefined) return
  await appendAndPublish(services.db, fanout, "workspace.updated", current.id, {
    ...current,
    archiveKeptArtifacts: keptArtifacts
  })
}

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
  if (restored.unrestoredArtifacts.length > 0) {
    await appendAndPublish(services.db, fanout, "workspace.updated", workspace.id, {
      ...restored.workspace,
      archiveUnrestoredArtifacts: restored.unrestoredArtifacts
    })
  }
  if (!restored.restoredFiles) {
    await appendAndPublish(services.db, fanout, "workspace.updated", workspace.id, {
      ...restored.workspace,
      archiveRestoreIncomplete: true
    })
    return restored.workspace
  }
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
