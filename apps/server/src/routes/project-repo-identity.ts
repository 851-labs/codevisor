import type { Project } from "@codevisor/api"
import { scratchWorkspacesRoot, type CodevisorDatabaseService } from "@codevisor/db"
import { gitRemoteUrl } from "@codevisor/worktrees"
import { dirname } from "node:path"
import {
  appendAndPublish,
  existingDirectory,
  run,
  swallowError,
  type EventFanout
} from "../server-context.js"

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
): Promise<ReadonlyArray<Project>> =>
  Promise.all(
    projects.map(async (project) => {
      const location = project.locations.find((candidate) => candidate.serverId === serverId)
      if (
        location === undefined ||
        existingDirectory(location.folderPath) === undefined ||
        dirname(location.folderPath) === scratchWorkspacesRoot()
      ) {
        return project
      }
      const url = await discoverRepoUrl(location.folderPath, env)
      if (url === undefined || url === project.repoUrl) {
        return project
      }
      try {
        const updated = await run(db.setProjectRepoUrl(project.id, url))
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
    })
  )

/// Startup backfill: projects recorded by releases that never observed a
/// remote get one the first time this server boots, with `project.updated`
/// events so already-connected clients regroup without a manual refresh.
export const backfillProjectRepoUrls = async (
  db: CodevisorDatabaseService,
  serverId: string,
  fanout: EventFanout,
  resolveEnvironment?: () => Promise<NodeJS.ProcessEnv>
): Promise<void> => {
  const projects = await run(db.listProjects)
  const env = await (resolveEnvironment?.() ?? Promise.resolve(process.env))
  await reconcileProjectRepoUrls(db, serverId, projects, env, fanout)
}
