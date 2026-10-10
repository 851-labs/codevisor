import { mkdirSync, readdirSync, rmdirSync } from "node:fs"
import type { IncomingMessage, ServerResponse } from "node:http"
import { homedir } from "node:os"
import { dirname, isAbsolute, relative, resolve } from "node:path"

import type { Project } from "@codevisor/api"
import {
  CreateProjectRequest as CreateProjectRequestSchema,
  CreateScratchProjectRequest as CreateScratchProjectRequestSchema,
  UpdateProjectRequest as UpdateProjectRequestSchema
} from "@codevisor/api"
import { scratchWorkspacePath, scratchWorkspacesRoot, worktreesRoot } from "@codevisor/db"
import { isGitWorkTree, listProjectGitBranches, trashDirectory } from "@codevisor/worktrees"
import { availableDevelopmentWorktreeName } from "@codevisor/worktrees"
import { availableProductionWorktreeName } from "@codevisor/worktrees"

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
import { routeProjectFromGit } from "./project-clone.js"
import { probeProject } from "./project-probe.js"
import { projectRecommendationsForRequest } from "./project-recommendations.js"
import { discoverRepoUrl, reconcileProjectRepoUrls } from "./project-repo-identity.js"
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
  // Each list refreshes this machine's view of every folder's remote
  // (memoized), so a remote added after the project was — or a project
  // recorded before remotes were tracked — links up without a restart.
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
  // A folder-added project is born with its remote, so it groups with
  // its siblings on other machines from the first list.
  const repoUrl =
    payload.repoUrl ??
    (existingDirectory(payload.folderPath) === undefined
      ? undefined
      : await discoverRepoUrl(
          payload.folderPath,
          await (services.resolveGitEnvironment?.() ?? Promise.resolve(process.env))
        ))
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

const allocateScratchWorkspaceFolder = (config: CodevisorServerConfig): string => {
  mkdirSync(scratchWorkspacesRoot(), { recursive: true })
  // Folder allocation doubles as the name reservation: a plain (non
  // recursive) mkdir fails on a name already claimed by any other server or
  // an earlier crash, so the loop simply draws again.
  const taken = new Set(readdirSync(scratchWorkspacesRoot()))
  let name: string | undefined
  for (let attempt = 0; attempt < 100 && name === undefined; attempt += 1) {
    const candidate =
      config.worktreeNameStyle === "development"
        ? availableDevelopmentWorktreeName(taken)
        : availableProductionWorktreeName(taken)
    try {
      mkdirSync(scratchWorkspacePath(candidate))
      name = candidate
    } catch {
      /* v8 ignore next -- requires another process to claim the random candidate between the directory scan and mkdir. */
      taken.add(candidate)
    }
  }
  /* v8 ignore next 3 -- 100 straight collisions needs an exhausted name pool; the loop bound is a backstop. */
  if (name === undefined) {
    throw new HttpFailure(500, "Could not allocate a scratch workspace folder")
  }
  return name
}

const writeExistingScratchProject = async (
  services: CodevisorServerServices,
  serverId: string,
  requestedId: string,
  response: ServerResponse
): Promise<boolean> => {
  const existing = (await run(services.db.listProjects)).find(
    (candidate) => candidate.id.toLowerCase() === requestedId.toLowerCase()
  )
  if (existing !== undefined) {
    writeJson(response, 200, await probeProject(serverId, existing))
    return true
  }
  return false
}

const createScratchProject = async (
  services: CodevisorServerServices,
  config: CodevisorServerConfig,
  fanout: EventFanout,
  serverId: string,
  request: IncomingMessage,
  response: ServerResponse
): Promise<boolean> => {
  const payload = await readSchema(request, CreateScratchProjectRequestSchema)
  // Idempotency: re-posting a client-supplied id returns the existing
  // project instead of allocating a second folder for the same workspace.
  const requestedId = payload.id
  if (requestedId !== undefined) {
    if (await writeExistingScratchProject(services, serverId, requestedId, response)) return true
  }
  const name = allocateScratchWorkspaceFolder(config)
  const project = await run(
    services.db.createProject({
      ...(payload.id === undefined ? {} : { id: payload.id }),
      folderPath: scratchWorkspacePath(name),
      name
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
  } catch {
    // Non-empty or already gone: leave it.
  }
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
    // "Delete Project and Files": the checkout itself goes too.
    const trashed = await trashDirectory(folderPath, {
      trashRoot: worktreeTrashRoot(),
      id: `project-${projectId}`
    })
    archiveJobs(services).track(trashed.purged)
  } else if (folderPath !== undefined && dirname(folderPath) === scratchWorkspacesRoot()) {
    // Deleting a scratch project retires its workspace folder too — but
    // only when the folder is still empty. Anything the user put there
    // stays on disk rather than vanishing with the row.
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
  const targets = (await run(services.db.listProjects)).filter(
    (candidate) => candidate.id.toLowerCase() === projectId.toLowerCase()
  )
  // Deleting a project is permanent and takes its chats with it, so the
  // files it owns must go too. Row deletion cascades; the filesystem does
  // not, and every worktree directory, branch and snapshot ref would
  // otherwise stay behind with nothing left to name it.
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

/// A project folder the server may delete along with its project. Never the
/// filesystem root, the home folder, or anything that contains them or
/// Codevisor's own worktree root: a project registered at such a path would
/// otherwise take far more than its checkout with it.
export const isDeletableProjectFolder = (folderPath: string): boolean => {
  if (!isAbsolute(folderPath)) return false
  const folder = resolve(folderPath)
  const contains = (path: string): boolean => {
    const inside = relative(folder, resolve(path))
    return inside === "" || (!inside.startsWith("..") && !isAbsolute(inside))
  }
  return ![homedir(), worktreesRoot()].some(contains)
}
