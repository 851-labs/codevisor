import type { GitPullRequest, Workspace } from "@codevisor/api"
import type { CodevisorDatabaseService } from "@codevisor/db"
import { findGitPullRequest, gitCurrentBranch, type OwnedBranch } from "@codevisor/worktrees"

import { failureMessage, run, type EventFanout } from "../server-context.js"
import type { WorkspaceGitCheckout } from "../server-workspace-effects.js"
import { field, stringField } from "../unknown-values.js"

export interface WorkspaceGitMonitorOptions {
  readonly db: CodevisorDatabaseService
  readonly fanout: EventFanout
  readonly checkout: (workspace: Workspace) => Promise<WorkspaceGitCheckout | undefined>
  readonly environment: (directory: string) => Promise<NodeJS.ProcessEnv>
  readonly branchOf?: (directory: string, env: NodeJS.ProcessEnv) => Promise<string | null>
  readonly pullRequestOf?: (
    directory: string,
    env: NodeJS.ProcessEnv,
    branch: string,
    owned?: OwnedBranch
  ) => Promise<GitPullRequest | null | undefined>
  readonly branchIntervalMs?: number
  readonly pullRequestIntervalMs?: number
}

export interface WorkspaceGitMonitor {
  readonly sweep: (pullRequests: boolean) => Promise<void>
  readonly settled: () => Promise<void>
  readonly close: () => Promise<void>
}

const concurrency = 4

const settledArchive = (workspace: Workspace): boolean =>
  workspace.isArchived && workspace.git !== undefined && workspace.git.pullRequest?.state !== "open"

const skips = (workspace: Workspace, pullRequests: boolean): boolean =>
  settledArchive(workspace) ||
  (workspace.isArchived && workspace.git !== undefined && !pullRequests)

/* v8 ignore next 3 */
const swallow = (cause: unknown): void => {
  console.error(`Workspace git sweep failed: ${failureMessage(cause)}`)
}

export const startWorkspaceGitMonitor = ({
  db,
  fanout,
  checkout,
  environment,
  branchOf = gitCurrentBranch,
  pullRequestOf = findGitPullRequest,
  branchIntervalMs = 30_000,
  pullRequestIntervalMs = 120_000
}: WorkspaceGitMonitorOptions): WorkspaceGitMonitor => {
  const queued = new Map<string, { workspace: Workspace | undefined; pullRequest: boolean }>()
  const working = new Set<string>()
  let draining: Promise<void> | undefined
  let closed = false

  const record = async (
    workspaceId: string,
    branch: string | null,
    pullRequest: GitPullRequest | null | undefined
  ): Promise<void> => {
    for (const event of await run(db.setWorkspaceGit(workspaceId, branch, pullRequest))) {
      await run(fanout.publish(event))
    }
  }

  const inspect = async (workspace: Workspace, wantsPullRequest: boolean): Promise<void> => {
    if (skips(workspace, wantsPullRequest)) return
    const found = await checkout(workspace)
    if (found === undefined) {
      if (!workspace.isArchived || workspace.git === undefined)
        await record(workspace.id, null, null)
      return
    }
    const env = await environment(found.directory)
    const branch = found.branch ?? (await branchOf(found.directory, env))
    const branchChanged = workspace.git?.branch !== branch
    let pullRequest: GitPullRequest | null | undefined
    if (branch === null) {
      pullRequest = null
    } else if (wantsPullRequest || branchChanged) {
      pullRequest = await pullRequestOf(found.directory, env, branch, found.ownedBranch)
      if (pullRequest === undefined && branchChanged) pullRequest = null
    }
    await record(workspace.id, branch, pullRequest)
  }

  const drain = (): Promise<void> => {
    if (draining !== undefined || queued.size === 0) return draining ?? Promise.resolve()
    draining = (async () => {
      try {
        while (queued.size > 0) {
          const batch = [...queued].slice(0, concurrency)
          for (const [id] of batch) queued.delete(id)
          const needsLookup = batch.some(([, entry]) => entry.workspace === undefined)
          const workspaces = needsLookup ? await run(db.listWorkspaces) : []
          await Promise.all(
            batch.map(async ([id, entry]) => {
              const workspace =
                entry.workspace ?? workspaces.find((candidate) => candidate.id.toLowerCase() === id)
              if (workspace === undefined) return
              await inspect(workspace, entry.pullRequest).catch((cause: unknown) => {
                console.error(`Workspace git check failed for ${id}: ${failureMessage(cause)}`)
              })
            })
          )
        }
      } finally {
        draining = undefined
      }
    })()
    return draining
  }

  const enqueue = (id: string, pullRequest: boolean, workspace?: Workspace): void => {
    if (closed) return
    const key = id.toLowerCase()
    queued.set(key, {
      workspace,
      pullRequest: pullRequest || (queued.get(key)?.pullRequest ?? false)
    })
    void drain()
  }

  const sweeps = new Set<Promise<void>>()
  const sweep = (pullRequests: boolean): Promise<void> => {
    const pass = (async () => {
      for (const workspace of await run(db.listWorkspaces)) {
        if (skips(workspace, pullRequests)) continue
        enqueue(workspace.id, pullRequests || workspace.git === undefined, workspace)
      }
      await drain()
    })()
    sweeps.add(pass)
    return pass.finally(() => sweeps.delete(pass))
  }

  const unsubscribe = fanout.subscribe((event) => {
    if (event.kind === "workspace.updated") {
      enqueue(event.subjectId, field(event.payload, "git") === undefined)
      return
    }
    if (event.kind === "session.deleted") {
      working.delete(event.subjectId)
      return
    }
    if (event.kind !== "session.attention.updated") return
    if (stringField(event.payload, "sidebarState") === "inProgress") {
      working.add(event.subjectId)
      return
    }
    if (!working.delete(event.subjectId)) return
    const workspaceId = stringField(event.payload, "workspaceId")
    if (workspaceId !== undefined) enqueue(workspaceId, true)
  })

  void sweep(true).catch(swallow)
  /* v8 ignore start */
  const branchSweep = setInterval(() => void sweep(false).catch(swallow), branchIntervalMs)
  const pullRequestSweep = setInterval(() => void sweep(true).catch(swallow), pullRequestIntervalMs)
  /* v8 ignore stop */
  branchSweep.unref()
  pullRequestSweep.unref()

  const settled = async (): Promise<void> => {
    if (sweeps.size === 0 && draining === undefined) return
    await Promise.allSettled([...sweeps, draining])
    await settled()
  }

  return {
    sweep,
    settled,
    close: async () => {
      closed = true
      clearInterval(branchSweep)
      clearInterval(pullRequestSweep)
      unsubscribe()
      await settled()
    }
  }
}
