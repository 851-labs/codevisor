import { rmdirSync } from "node:fs"
import type { IncomingMessage, ServerResponse } from "node:http"
import { homedir } from "node:os"
import { isAbsolute, relative, resolve } from "node:path"

import type { Project } from "@codevisor/api"
import {
  CreateProjectRequest as CreateProjectRequestSchema,
  UpdateProjectRequest as UpdateProjectRequestSchema
} from "@codevisor/api"
import { isScratchFolder, worktreesRoot } from "@codevisor/db"
import { isGitWorkTree, listProjectGitBranches, trashDirectory } from "@codevisor/worktrees"

import {
  appendAndPublish,
  archiveJobs,
  discardProjectWorktrees,
  assertLocationFolderExists,
  existingDirectory,
  getProjectOrFail,
  HttpFailure,
  localLocationOrFail,
  matchRoute,
  readSchema,
  run,
  worktreeTrashRoot,
  writeJson,
  type CodevisorServerConfig,
  type CodevisorServerServices,
  type EventFanout
} from "../server-context.js"
import { assertNotOwnedByBot } from "./bot-guards.js"
import { routeProjectCloneSettings } from "./project-clone-settings.js"
import { cancelProjectSetup, routeProjectFromGit } from "./project-clone.js"
import { probeProject } from "./project-probe.js"
import { projectRecommendationsForRequest } from "./project-recommendations.js"
import { routePublishProjectRemote } from "./project-remote.js"
import { discoverRepoUrl, reconcileProjectRepoUrls } from "./project-repo-identity.js"
import { createScratchProject } from "./project-scratch.js"
import { routeProjectSetupSource, routeReadProjectEnvFiles } from "./project-setup-source.js"
import { createProjectWorktree } from "./project-worktree-create.js"

export { probeProject } from "./project-probe.js"

export const routeProjects = async (
  services: CodevisorServerServices,
  config: CodevisorServerConfig,
  fanout: EventFanout,
  request: IncomingMessage,
  response: ServerResponse,
  url: URL
): Promise<boolean> => {
  const serverId = config.id
  if (request.method === "GET" && url.pathname === "/v1/projects")
    return listProjects(services, serverId, response)
  if (request.method === "GET" && url.pathname === "/v1/projects/recommendations") {
    writeJson(response, 200, await projectRecommendationsForRequest(services, url))
    return true
  }
  if (request.method === "POST" && url.pathname === "/v1/projects")
    return createProject(services, fanout, serverId, request, response)
  if (request.method === "POST" && url.pathname === "/v1/projects/from-git") {
    await routeProjectFromGit(services, fanout, serverId, request, response)
    return true
  }
  if (url.pathname === "/v1/projects/clone-settings") {
    await routeProjectCloneSettings(services.db, request, response)
    return true
  }
  const cancelSetupId = matchRoute(url.pathname, "/v1/projects/from-git/:id")
  if (cancelSetupId !== undefined && request.method === "DELETE") {
    if (!cancelProjectSetup(cancelSetupId)) {
      throw new HttpFailure(404, `No setup in progress for ${cancelSetupId}`)
    }
    response.writeHead(204).end()
    return true
  }
  const setupSourceId = matchRoute(url.pathname, "/v1/projects/:id/setup-source")
  if (setupSourceId !== undefined && request.method === "GET") {
    await routeProjectSetupSource(services, serverId, setupSourceId, response)
    return true
  }
  const remoteId = matchRoute(url.pathname, "/v1/projects/:id/remote")
  if (remoteId !== undefined && request.method === "POST") {
    await routePublishProjectRemote(services, fanout, serverId, remoteId, request, response)
    return true
  }
  const envFilesId = matchRoute(url.pathname, "/v1/projects/:id/env-files/read")
  if (envFilesId !== undefined && request.method === "POST") {
    await routeReadProjectEnvFiles(services, serverId, envFilesId, request, response)
    return true
  }
  if (request.method === "POST" && url.pathname === "/v1/projects/scratch")
    return createScratchProject(services, config, fanout, serverId, request, response)

  const projectId = matchRoute(url.pathname, "/v1/projects/:id")
  if (projectId !== undefined && request.method === "PATCH")
    return updateProject(services, fanout, serverId, projectId, request, response)
  if (projectId !== undefined && request.method === "DELETE")
    return deleteProject(services, config, fanout, serverId, projectId, response, url)
  const branchProjectId = matchRoute(url.pathname, "/v1/projects/:id/git/branches")
  if (branchProjectId !== undefined && request.method === "GET")
    return listProjectBranches(services, serverId, branchProjectId, response)
  const worktreeProjectId = matchRoute(url.pathname, "/v1/projects/:id/worktrees")
  if (worktreeProjectId !== undefined && request.method === "GET") {
    writeJson(response, 200, await run(services.db.listWorktrees(worktreeProjectId)))
    return true
  }
  if (worktreeProjectId !== undefined && request.method === "POST")
    return createProjectWorktree(
      services,
      config,
      fanout,
      serverId,
      worktreeProjectId,
      request,
      response
    )
  return false
}

const listProjects = async (
  services: CodevisorServerServices,
  serverId: string,
  response: ServerResponse
): Promise<boolean> => {
  const environment = await (services.resolveGitEnvironment?.() ?? Promise.resolve(process.env))
  const projects = await reconcileProjectRepoUrls(
    services.db,
    serverId,
    await run(services.db.listProjects),
    environment
  )
  writeJson(
    response,
    200,
    await Promise.all(projects.map((project) => probeProject(serverId, project)))
  )
  return true
}

const createProject = async (
  services: CodevisorServerServices,
  fanout: EventFanout,
  serverId: string,
  request: IncomingMessage,
  response: ServerResponse
): Promise<boolean> => {
  const payload = await readSchema(request, CreateProjectRequestSchema)
  let repoUrl = payload.repoUrl
  if (repoUrl === undefined && existingDirectory(payload.folderPath) !== undefined) {
    repoUrl = await discoverRepoUrl(
      payload.folderPath,
      await (services.resolveGitEnvironment?.() ?? Promise.resolve(process.env))
    )
  }
  const project = await run(
    services.db.createProject({
      ...payload,
      ...(repoUrl === undefined ? {} : { repoUrl })
    })
  )
  await appendAndPublish(services.db, fanout, "project.created", project.id, project)
  writeJson(response, 201, await probeProject(serverId, project))
  return true
}

const updateProject = async (
  services: CodevisorServerServices,
  fanout: EventFanout,
  serverId: string,
  projectId: string,
  request: IncomingMessage,
  response: ServerResponse
): Promise<boolean> => {
  const payload = await readSchema(request, UpdateProjectRequestSchema)
  const project = await run(services.db.updateProject(projectId, payload))
  await appendAndPublish(services.db, fanout, "project.updated", project.id, project)
  writeJson(response, 200, await probeProject(serverId, project))
  return true
}

const retireEmptyScratchFolder = (folderPath: string): void => {
  try {
    rmdirSync(folderPath)
  } catch {}
}

const deleteProjectFolder = async (
  services: CodevisorServerServices,
  serverId: string,
  projectId: string,
  targets: ReadonlyArray<Project>,
  url: URL
): Promise<void> => {
  const folderPath = targets
    .flatMap((target) => target.locations)
    .find((location) => location.serverId === serverId)?.folderPath
  if (
    folderPath !== undefined &&
    url.searchParams.get("deleteFiles") === "true" &&
    isDeletableProjectFolder(folderPath)
  ) {
    const trashed = await trashDirectory(folderPath, {
      trashRoot: worktreeTrashRoot(),
      id: `project-${projectId}`
    })
    archiveJobs(services).track(trashed.purged)
  } else if (folderPath !== undefined && isScratchFolder(folderPath)) {
    retireEmptyScratchFolder(folderPath)
  }
}

const deleteProject = async (
  services: CodevisorServerServices,
  config: CodevisorServerConfig,
  fanout: EventFanout,
  serverId: string,
  projectId: string,
  response: ServerResponse,
  url: URL
): Promise<boolean> => {
  await assertNotOwnedByBot(services, { projectId }, "delete this project")
  const targets = (await run(services.db.listProjects)).filter(
    (candidate) => candidate.id.toLowerCase() === projectId.toLowerCase()
  )
  for (const target of targets) await discardProjectWorktrees(services, config.id, target)
  await run(services.db.deleteProject(projectId))
  await appendAndPublish(services.db, fanout, "project.deleted", projectId, {
    id: projectId
  })
  await deleteProjectFolder(services, serverId, projectId, targets, url)
  writeJson(response, 204, undefined)
  return true
}

const listProjectBranches = async (
  services: CodevisorServerServices,
  serverId: string,
  branchProjectId: string,
  response: ServerResponse
): Promise<boolean> => {
  const project = await getProjectOrFail(services.db, branchProjectId)
  const location = localLocationOrFail(serverId, project)
  assertLocationFolderExists(location)
  if (!(await isGitWorkTree(location.folderPath))) {
    throw new HttpFailure(422, `Project folder is not a git repository: ${location.folderPath}`)
  }
  const environment = await (services.resolveGitEnvironment?.() ?? Promise.resolve(process.env))
  writeJson(response, 200, await listProjectGitBranches(location.folderPath, environment))
  return true
}

export const isDeletableProjectFolder = (folderPath: string): boolean => {
  if (!isAbsolute(folderPath)) return false
  const folder = resolve(folderPath)
  const contains = (path: string): boolean => {
    const inside = relative(folder, resolve(path))
    return inside === "" || (!inside.startsWith("..") && !isAbsolute(inside))
  }
  return ![homedir(), worktreesRoot()].some(contains)
}
