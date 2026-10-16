import { stat } from "node:fs/promises"

import type { Project } from "@codevisor/api"
import { isManagedFolder, type CodevisorDatabaseService } from "@codevisor/db"
import { gitRemoteUrl, isGitWorkTree } from "@codevisor/worktrees"

import { appendAndPublish, run, swallowError, type EventFanout } from "../server-context.js"

const discoveryTtlMs = 60_000
const discovered = new Map<string, { readonly url: string | undefined; readonly at: number }>()

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
    if (location === undefined || isManagedFolder(location.folderPath)) {
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
        ...(remoteChanged ? await run(db.setProjectRepoUrl(project.id, url)) : project),
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
      /* v8 ignore next */
      return project
    }
  }
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
