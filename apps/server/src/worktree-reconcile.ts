import { existsSync } from "node:fs"

import type { Project } from "@codevisor/api"
import { archivedArtifactsPath } from "@codevisor/db"
import {
  deleteSnapshot,
  keepArtifacts,
  listSnapshotRefWorktreeIds,
  pruneWorktreeRegistrations,
  releaseBranch,
  removeArchivedWorktreeFiles,
  trashDirectory
} from "@codevisor/worktrees"

import { archiveJobs, enqueueWorkspaceArchive } from "./archive-jobs.js"
import type {
  CodevisorServerConfig,
  CodevisorServerServices,
  EventFanout
} from "./server-context-types.js"
import { localLocationOrFail, run } from "./server-http.js"
import { worktreeTrashRoot } from "./server-workspace-effects.js"

const repoDirFor = async (
  services: CodevisorServerServices,
  serverId: string,
  projectId: string
): Promise<string | undefined> => {
  try {
    const project = (await run(services.db.listProjects)).find(
      (candidate) => candidate.id.toLowerCase() === projectId.toLowerCase()
    )
    /* v8 ignore next */
    if (project === undefined) return undefined
    return localLocationOrFail(serverId, project).folderPath
  } catch {
    return undefined
  }
}

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
        await pruneWorktreeRegistrations(repoDir, environment)
        await releaseBranch(repoDir, archived.branch, environment)
      } else {
        await keepArtifacts(worktree.path, archivedArtifactsPath(archived.id), environment)
        const trashed = await removeArchivedWorktreeFiles(repoDir, worktree.path, archived.branch, {
          trashRoot: worktreeTrashRoot(),
          worktreeId: archived.id,
          env: environment
        })
        archiveJobs(services).track(trashed.purged)
      }
      await run(services.db.createArchivedWorktree({ ...archived, state: "complete" }))
      if (worktree !== undefined) await run(services.db.deleteWorktree(worktree.id))
    } catch {}
  }
}

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
      if (archivedIds.has(worktree.id.toLowerCase())) continue
      await run(services.db.deleteWorktree(worktree.id))
    }
  }
}

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
      await discardSnapshot(services, repoDir, worktreeId, environment)
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
    } catch {}
  }
  for (const archived of await run(services.db.listArchivedWorktrees(project.id))) {
    if (archived.serverId !== serverId) continue
    await discardSnapshot(services, location.folderPath, archived.id, environment)
  }
  await pruneWorktreeRegistrations(location.folderPath, environment)
}

const discardSnapshot = async (
  services: CodevisorServerServices,
  repoDir: string,
  worktreeId: string,
  environment: NodeJS.ProcessEnv
): Promise<void> => {
  await deleteSnapshot(repoDir, worktreeId, environment)
  const trashed = await trashDirectory(archivedArtifactsPath(worktreeId), {
    trashRoot: worktreeTrashRoot(),
    id: `artifacts-${worktreeId}`
  })
  archiveJobs(services).track(trashed.purged)
}
