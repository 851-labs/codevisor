import { stat } from "node:fs/promises"
import { dirname } from "node:path"

import type { Project } from "@codevisor/api"
import { scratchWorkspacesRoot, type CodevisorDatabaseService } from "@codevisor/db"
import { gitRemoteUrl, isGitWorkTree } from "@codevisor/worktrees"

import { appendAndPublish, run, swallowError, type EventFanout } from "../server-context.js"

/// A project's git remote is the machine-independent half of its identity:
/// two machines that each hold a checkout of the same remote are showing the
/// user one project. The remote is observed from the folder rather than
/// asked for, so projects added from a local directory, managed clones, and
/// rows created by older releases (which never recorded one) all line up.
///
/// Discovery spawns git, so results are memoized per folder for a minute:
/// the project list is fetched on every navigation refresh, and a remote
/// changes about as often as a repository is re-cloned.
const discoveryTtlMs = 60_000
const discovered = new Map<string, { readonly url: string | undefined; readonly at: number }>()

/// Test seam: forget memoized results so a folder re-probes immediately.
export const resetRepoUrlDiscoveryCache = (): void => {
  discovered.clear()
}

export const discoverRepoUrl = async (
  folderPath: string,
  env?: NodeJS.ProcessEnv
): Promise<string | undefined> => {
  const cached = discovered.get(folderPath)
  const now = Date.now()
  if (cached !== undefined && now - cached.at < discoveryTtlMs) {
    return cached.url
  }
  const url = await gitRemoteUrl(folderPath, env)
  discovered.set(folderPath, { url, at: now })
  return url
}

/// Brings each project's stored `repoUrl` in line with the remote actually
/// configured in its folder on this machine, persisting any difference.
/// A folder that is missing, not a repository, or has no remote leaves the
/// stored value alone (a clone-from-git project keeps the URL it was cloned
/// from even while its checkout is temporarily unreadable). Scratch folders
/// are skipped outright: they are never repositories, and probing each one
/// on every list would be wasted spawns.
///
/// Every machine reconciles only its own rows, so a fleet whose servers
/// update at different times converges without coordination: an old
/// server simply reports no remote for its folder projects until it is
/// upgraded, and clients treat those as unlinked in the meantime.
export const reconcileProjectRepoUrls = async (
  db: CodevisorDatabaseService,
  serverId: string,
  projects: ReadonlyArray<Project>,
  env?: NodeJS.ProcessEnv,
  fanout?: EventFanout
): Promise<ReadonlyArray<Project>> => {
  const results = [...projects]
  const reconcile = async (project: Project): Promise<Project> => {
    const location = project.locations.find((candidate) => candidate.serverId === serverId)
    if (location === undefined || dirname(location.folderPath) === scratchWorkspacesRoot()) {
      return project
    }
    const exists = (await stat(location.folderPath).catch(() => undefined))?.isDirectory() === true
    const isGitRepository = exists && (await isGitWorkTree(location.folderPath))
    const url = isGitRepository ? await discoverRepoUrl(location.folderPath, env) : undefined
    const locationChanged = isGitRepository !== location.isGitRepository
    const remoteChanged = url !== undefined && url !== project.repoUrl
    if (!locationChanged && !remoteChanged) return project
    try {
      if (locationChanged) await run(db.setProjectLocationGitState(location.id, isGitRepository))
      const updated = {
        ...(remoteChanged ? await run(db.setProjectRepoUrl(project.id, url!)) : project),
        locations: project.locations.map((value) =>
          value.id === location.id ? { ...value, isGitRepository } : value
        )
      }
      if (fanout !== undefined) {
        await appendAndPublish(db, fanout, "project.updated", updated.id, updated).catch(
          swallowError
        )
      }
      return updated
    } catch {
      /* v8 ignore next -- a row deleted between the list and the write; the stale copy is still fine to return. */
      return project
    }
  }
  // Repository observation never holds a navigation request or starts an
  // unbounded wave of Git processes for a large project catalog.
  let next = 0
  const worker = async (): Promise<void> => {
    while (next < projects.length) {
      const index = next++
      results[index] = await reconcile(projects[index]!)
    }
  }
  await Promise.all([worker(), worker()])
  return results
}

/// Startup backfill: projects recorded by releases that never observed a
/// remote get one the first time this server boots, with `project.updated`
/// events so already-connected clients regroup without a manual refresh.
const refreshes = new WeakMap<CodevisorDatabaseService, Promise<void>>()
export const backfillProjectRepoUrls = async (
  db: CodevisorDatabaseService,
  serverId: string,
  fanout: EventFanout,
  resolveEnvironment?: () => Promise<NodeJS.ProcessEnv>
): Promise<void> => {
  const running = refreshes.get(db)
  if (running !== undefined) return running
  const task = (async () => {
    const projects = await run(db.listProjects)
    const env = await (resolveEnvironment?.() ?? Promise.resolve(process.env))
    await reconcileProjectRepoUrls(db, serverId, projects, env, fanout)
  })()
  refreshes.set(db, task)
  try {
    await task
  } finally {
    refreshes.delete(db)
  }
}
