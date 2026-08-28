import { randomUUID } from "node:crypto"
import type { Project, ProjectSetupUpdate, Worktree, WorktreeSetupUpdate } from "@codevisor/api"
import {
  CreateProjectFromGitRequest as CreateProjectFromGitRequestSchema,
  CreateProjectRequest as CreateProjectRequestSchema,
  CreateScratchProjectRequest as CreateScratchProjectRequestSchema,
  CreateWorktreeRequest as CreateWorktreeRequestSchema,
  UpdateProjectRequest as UpdateProjectRequestSchema
} from "@codevisor/api"
import {
  DatabaseError,
  managedRepoPath,
  scratchWorkspacePath,
  scratchWorkspacesRoot,
  type CodevisorDatabaseService
} from "@codevisor/db"
import { existsSync, mkdirSync, readdirSync, rmSync, rmdirSync } from "node:fs"
import type { IncomingMessage, ServerResponse } from "node:http"
import { dirname } from "node:path"
import {
  CloneError,
  addWorktree,
  cloneRepository,
  isGitWorkTree,
  isWorktreeBranchCollision,
  listCodevisorWorktreeBranchNames,
  listProjectGitBranches,
  rollbackFailedWorktree,
  worktreeStartPoint
} from "@codevisor/worktrees"
import { availableDevelopmentWorktreeName } from "@codevisor/worktrees"
import { availableProductionWorktreeName } from "@codevisor/worktrees"
import {
  appendAndPublish,
  applyCascadedSessionEffects,
  assertLocationFolderExists,
  existingDirectory,
  failureMessage,
  getProjectOrFail,
  HttpFailure,
  localLocationOrFail,
  matchRoute,
  publishChangedWorkspaces,
  readSchema,
  run,
  swallowError,
  writeJson,
  type CodevisorServerConfig,
  type CodevisorServerServices,
  type EventFanout
} from "../server-context.js"
import { cloneDirectoryName, looksLikeGitUrl } from "./project-git-url.js"
import { projectRecommendationsForRequest } from "./project-recommendations.js"

export const routeProjects = async (
  services: CodevisorServerServices,
  config: CodevisorServerConfig,
  fanout: EventFanout,
  request: IncomingMessage,
  response: ServerResponse,
  url: URL
): Promise<boolean> => {
  const serverId = config.id
  if (request.method === "GET" && url.pathname === "/v1/projects") {
    const projects = await run(services.db.listProjects)
    writeJson(
      response,
      200,
      await Promise.all(projects.map((project) => probeProject(serverId, project)))
    )
    return true
  }

  if (request.method === "GET" && url.pathname === "/v1/projects/recommendations") {
    writeJson(response, 200, await projectRecommendationsForRequest(services, url))
    return true
  }

  if (request.method === "POST" && url.pathname === "/v1/projects") {
    const project = await run(
      services.db.createProject(await readSchema(request, CreateProjectRequestSchema))
    )
    await appendAndPublish(services.db, fanout, "project.created", project.id, project)
    writeJson(response, 201, await probeProject(serverId, project))
    return true
  }

  if (request.method === "POST" && url.pathname === "/v1/projects/from-git") {
    const payload = await readSchema(request, CreateProjectFromGitRequestSchema)
    const repoUrl = payload.url.trim()
    if (!looksLikeGitUrl(repoUrl)) {
      throw new HttpFailure(400, `Not a git URL: ${payload.url}`, "invalid_url")
    }
    const name = payload.name?.trim() || cloneDirectoryName(repoUrl)
    if (name === undefined || name.length === 0) {
      throw new HttpFailure(
        400,
        "Could not derive a project name from the URL; pass one explicitly",
        "invalid_url"
      )
    }
    const destination = managedRepoPath(name)
    if (existsSync(destination)) {
      throw new HttpFailure(
        409,
        `${destination} already exists on this machine; add it as a local directory instead`,
        "already_exists"
      )
    }

    const newProjectId = payload.id ?? randomUUID()
    const publishSetup = makeProjectSetupPublisher(services.db, fanout, newProjectId, repoUrl)
    const startedAt = Date.now()
    await publishSetup({ state: "started" })
    try {
      mkdirSync(dirname(destination), { recursive: true })
      const environment = await (services.resolveGitEnvironment?.() ?? Promise.resolve(process.env))
      await cloneRepository(
        repoUrl,
        destination,
        (stream, line) => {
          void publishSetup({ state: "log", stream, line }).catch(swallowError)
        },
        environment
      )
      await publishSetup({ state: "completed", durationMs: Date.now() - startedAt })
    } catch (cause) {
      /* v8 ignore next -- cloneRepository always throws CloneError; the fallback guards mkdir failures. */
      const code = cause instanceof CloneError ? cause.code : undefined
      await publishSetup({
        state: "failed",
        message: failureMessage(cause),
        /* v8 ignore next -- spawn-level clone failures carry no classification; exercised directly in git.test.ts. */
        ...(code === undefined ? {} : { code }),
        durationMs: Date.now() - startedAt
      })
      // Never leave a partial checkout behind: the name must be retryable.
      /* v8 ignore next -- best-effort cleanup; a second fault still surfaces the git error. */
      rmSync(destination, { force: true, recursive: true })
      throw cause
    }

    const project = await run(
      services.db.createProject({
        id: newProjectId,
        folderPath: destination,
        name,
        repoUrl
      })
    )
    await appendAndPublish(services.db, fanout, "project.created", project.id, project)
    writeJson(response, 201, await probeProject(serverId, project))
    return true
  }

  if (request.method === "POST" && url.pathname === "/v1/projects/scratch") {
    const payload = await readSchema(request, CreateScratchProjectRequestSchema)
    // Idempotency: re-posting a client-supplied id returns the existing
    // project instead of allocating a second folder for the same workspace.
    const requestedId = payload.id
    if (requestedId !== undefined) {
      const existing = (await run(services.db.listProjects)).find(
        (candidate) => candidate.id.toLowerCase() === requestedId.toLowerCase()
      )
      if (existing !== undefined) {
        writeJson(response, 200, await probeProject(serverId, existing))
        return true
      }
    }
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

  const projectId = matchRoute(url.pathname, "/v1/projects/:id")
  if (projectId !== undefined && request.method === "PATCH") {
    const payload = await readSchema(request, UpdateProjectRequestSchema)
    // Captured before the write so the cascade's effects can be replayed for
    // exactly the children whose state changed.
    const sessionsBefore =
      payload.isArchived === undefined ? [] : await run(services.db.listSessions)
    const workspacesBefore =
      payload.isArchived === undefined ? [] : await run(services.db.listWorkspaces)
    const project = await run(services.db.updateProject(projectId, payload))
    await appendAndPublish(services.db, fanout, "project.updated", project.id, project)
    if (payload.isArchived !== undefined) {
      await publishChangedWorkspaces(services, fanout, workspacesBefore)
      await applyCascadedSessionEffects(services, fanout, config, sessionsBefore)
    }
    writeJson(response, 200, await probeProject(serverId, project))
    return true
  }

  if (projectId !== undefined && request.method === "DELETE") {
    const target = (await run(services.db.listProjects)).find(
      (candidate) => candidate.id.toLowerCase() === projectId.toLowerCase()
    )
    await run(services.db.deleteProject(projectId))
    await appendAndPublish(services.db, fanout, "project.deleted", projectId, {
      id: projectId
    })
    // Deleting a scratch project retires its workspace folder too — but only
    // when the folder is still empty. Anything the user put there stays on
    // disk rather than vanishing with the row.
    const folderPath = target?.locations.find(
      (location) => location.serverId === serverId
    )?.folderPath
    if (folderPath !== undefined && dirname(folderPath) === scratchWorkspacesRoot()) {
      try {
        rmdirSync(folderPath)
      } catch {
        // Non-empty or already gone: leave it.
      }
    }
    writeJson(response, 204, undefined)
    return true
  }

  const branchProjectId = matchRoute(url.pathname, "/v1/projects/:id/git/branches")
  if (branchProjectId !== undefined && request.method === "GET") {
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

  const worktreeProjectId = matchRoute(url.pathname, "/v1/projects/:id/worktrees")
  if (worktreeProjectId !== undefined && request.method === "GET") {
    writeJson(response, 200, await run(services.db.listWorktrees(worktreeProjectId)))
    return true
  }

  if (worktreeProjectId !== undefined && request.method === "POST") {
    const payload = await readSchema(request, CreateWorktreeRequestSchema)
    const project = await getProjectOrFail(services.db, worktreeProjectId)
    const location = localLocationOrFail(serverId, project)
    assertLocationFolderExists(location)
    if (!(await isGitWorkTree(location.folderPath))) {
      throw new HttpFailure(422, `Project folder is not a git repository: ${location.folderPath}`)
    }
    // Server data/worktree directories may be isolated, but local branches
    // belong to the shared Git repository. Include both namespaces so an
    // archived worktree or another development server cannot look available.
    const existing = new Set((await run(services.db.listWorktrees(project.id))).map((w) => w.name))
    for (const name of await listCodevisorWorktreeBranchNames(location.folderPath)) {
      existing.add(name)
    }
    const requested = slugifyWorktreeName(payload.name)
    // Refresh once, outside the collision loop. The ref check above handles
    // established conflicts; retrying `git worktree add -b` handles the race
    // where another isolated server claims the same branch after our scan.
    const environment = await (services.resolveGitEnvironment?.() ?? Promise.resolve(process.env))
    const startPoint = await worktreeStartPoint(
      location.folderPath,
      project.worktreeBase,
      environment
    )
    for (let attempt = 0; attempt < 100; attempt += 1) {
      const name =
        config.worktreeNameStyle === "development"
          ? availableDevelopmentWorktreeName(existing)
          : requested === undefined
            ? availableProductionWorktreeName(existing)
            : availableWorktreeName(requested, existing)
      const branch = `codevisor/${name}`
      let worktree: Worktree
      try {
        worktree = await run(services.db.createWorktree(project.id, name, branch, payload.id))
      } catch (cause) {
        // A concurrent request on this server can reserve the candidate after
        // our initial scan. Retry only the name constraint; a duplicate
        // client-supplied id or any other database failure is not recoverable
        // by changing the branch name.
        /* v8 ignore start -- requires a deterministic interleaving inside the database's atomic unique constraint. */
        if (isWorktreeNameCollision(cause) && attempt < 99) {
          existing.add(name)
          continue
        }
        throw cause
        /* v8 ignore stop */
      }
      const startedAt = Date.now()
      const publishSetup = makeWorktreeSetupPublisher(
        services.db,
        fanout,
        worktree,
        payload.sessionId
      )
      await publishSetup({ state: "started" })
      try {
        mkdirSync(dirname(worktree.path), { recursive: true })
        await addWorktree(
          location.folderPath,
          worktree.path,
          branch,
          (stream, line) => {
            void publishSetup({ state: "log", stream, line }).catch(swallowError)
          },
          startPoint,
          environment
        )
        await publishSetup({ state: "completed", durationMs: Date.now() - startedAt })
      } catch (cause) {
        // Release the reservation before retrying the same client-supplied id
        // under a new name. Only a branch collision is retryable; other Git
        // failures retain their terminal setup event and original response.
        /* v8 ignore start -- requires another process to claim a branch between the preflight scan and git worktree add. */
        await run(services.db.deleteWorktree(worktree.id)).catch(() => undefined)
        if (isWorktreeBranchCollision(cause) && attempt < 99) {
          existing.add(name)
          await publishSetup({
            state: "log",
            stream: "stderr",
            line: `Branch ${branch} was claimed concurrently; choosing another name.`
          })
          continue
        }
        try {
          if (
            await rollbackFailedWorktree(location.folderPath, worktree.path, branch, environment)
          ) {
            await publishSetup({
              state: "log",
              stream: "stderr",
              line: "Removed the partial worktree and branch."
            })
          }
        } catch (cleanupCause) {
          await publishSetup({
            state: "log",
            stream: "stderr",
            line: `Could not fully remove the partial worktree: ${failureMessage(cleanupCause)}`
          })
        }
        await publishSetup({
          state: "failed",
          message: failureMessage(cause),
          durationMs: Date.now() - startedAt
        })
        throw cause
        /* v8 ignore stop */
      }
      await appendAndPublish(services.db, fanout, "worktree.created", worktree.id, worktree)
      writeJson(response, 201, worktree)
      return true
    }
    /* v8 ignore next -- the allocator's candidate bound guarantees a free name before 100 attempts absent continuous external races. */
    throw new HttpFailure(422, "Unable to allocate an unused Git worktree branch")
  }

  return false
}

const slugifyWorktreeName = (name: string | undefined): string | undefined => {
  const slug = (name ?? "")
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "")
    .slice(0, 64)
    .replace(/-+$/g, "")
  return slug.length > 0 ? slug : undefined
}

/// Keeps explicit names readable and only adds a sequence number when the
/// requested name is already in use. The upper bound guarantees a free name:
/// existing.size + 1 distinct candidates cannot all appear in `existing`.
const availableWorktreeName = (base: string, existing: ReadonlySet<string>): string => {
  if (!existing.has(base)) {
    return base
  }
  for (let number = 2; number <= existing.size + 2; number += 1) {
    const suffix = `-${number}`
    const stem = base.slice(0, 64 - suffix.length).replace(/-+$/g, "")
    const candidate = `${stem}${suffix}`
    if (!existing.has(candidate)) {
      return candidate
    }
  }
  /* v8 ignore next -- existing.size + 1 candidates guarantee a free suffix. */
  throw new Error("Unable to allocate a unique worktree name")
}

/* v8 ignore start -- exercised only by the deliberately timing-dependent database race above. */
const isWorktreeNameCollision = (cause: unknown): boolean =>
  cause instanceof DatabaseError &&
  cause.operation === "createWorktree" &&
  cause.message.includes(
    "UNIQUE constraint failed: worktrees.project_id, worktrees.server_id, worktrees.name"
  )
/* v8 ignore stop */

type WorktreeSetupDetail = Omit<WorktreeSetupUpdate, "worktreeId" | "projectId" | "name" | "branch">

/// Serialized project.setup progress for clone-from-git, mirroring the
/// worktree.setup pattern: clients follow the client-supplied project id on
/// the event stream while the HTTP request is still in flight.
const makeProjectSetupPublisher = (
  db: CodevisorDatabaseService,
  fanout: EventFanout,
  projectId: string,
  repoUrl: string
): ((
  detail: Partial<ProjectSetupUpdate> & { state: ProjectSetupUpdate["state"] }
) => Promise<void>) => {
  let chain: Promise<void> = Promise.resolve()
  return (detail) => {
    const update: ProjectSetupUpdate = {
      projectId,
      url: repoUrl,
      ...detail
    }
    const next = chain.then(async () => {
      await appendAndPublish(db, fanout, "project.setup", projectId, update)
    })
    /* v8 ignore next -- keeps the chain alive if the event log write fails; awaited callers still see the failure via `next`. */
    chain = next.catch(() => undefined)
    return next
  }
}

const makeWorktreeSetupPublisher = (
  db: CodevisorDatabaseService,
  fanout: EventFanout,
  worktree: Worktree,
  mirrorSubjectId?: string
): ((detail: WorktreeSetupDetail) => Promise<void>) => {
  let chain: Promise<void> = Promise.resolve()
  return (detail) => {
    const update: WorktreeSetupUpdate = {
      worktreeId: worktree.id,
      projectId: worktree.projectId,
      name: worktree.name,
      branch: worktree.branch,
      ...detail
    }
    const next = chain.then(async () => {
      await appendAndPublish(db, fanout, "worktree.setup", worktree.id, update)
      if (mirrorSubjectId !== undefined) {
        await appendAndPublish(db, fanout, "worktree.setup", mirrorSubjectId, update)
      }
    })
    /* v8 ignore next -- keeps the chain alive if the event log write fails; awaited callers still see the failure via `next`. */
    chain = next.catch(() => undefined)
    return next
  }
}

/// Annotates this server's locations with whether their folder is a git
/// repository so clients can decide if the worktree option is available, and
/// marks scratch-workspace backing projects (folder under
/// ~/codevisor/workspaces) so clients can hide them from project pickers.
export const probeProject = async (serverId: string, project: Project): Promise<Project> => ({
  ...project,
  locations: await Promise.all(
    project.locations.map(async (location) =>
      location.serverId === serverId && existingDirectory(location.folderPath) !== undefined
        ? { ...location, isGitRepository: await isGitWorkTree(location.folderPath) }
        : location
    )
  ),
  ...(project.locations.some((location) => dirname(location.folderPath) === scratchWorkspacesRoot())
    ? { isScratch: true }
    : {})
})
