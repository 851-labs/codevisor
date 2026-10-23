import { mkdirSync } from "node:fs"
import type { IncomingMessage, ServerResponse } from "node:http"
import { dirname } from "node:path"

import type {
  CreateWorktreeRequest,
  Project,
  ProjectLocation,
  Worktree,
  WorktreeSetupUpdate
} from "@codevisor/api"
import { CreateWorktreeRequest as CreateWorktreeRequestSchema } from "@codevisor/api"
import { DatabaseError, type CodevisorDatabaseService } from "@codevisor/db"
import {
  addWorktree,
  isGitWorkTree,
  isWorktreeBranchCollision,
  listCodevisorWorktreeBranchNames,
  listRemoteCodevisorBranchNames,
  rollbackFailedWorktree,
  worktreeStartPoint
} from "@codevisor/worktrees"
import { availableDevelopmentWorktreeName } from "@codevisor/worktrees"
import { availableProductionWorktreeName } from "@codevisor/worktrees"

import {
  appendAndPublish,
  assertLocationFolderExists,
  failureMessage,
  getProjectOrFail,
  HttpFailure,
  localLocationOrFail,
  readSchema,
  run,
  swallowError,
  writeJson,
  type CodevisorServerConfig,
  type CodevisorServerServices,
  type EventFanout
} from "../server-context.js"
import { isScratchProject } from "./project-probe.js"

export const createProjectWorktree = async (
  services: CodevisorServerServices,
  config: CodevisorServerConfig,
  fanout: EventFanout,
  serverId: string,
  worktreeProjectId: string,
  request: IncomingMessage,
  response: ServerResponse
): Promise<boolean> => {
  const payload = await readSchema(request, CreateWorktreeRequestSchema)
  const { worktree } = await allocateProjectWorktree(
    { services, config, fanout, serverId },
    worktreeProjectId,
    payload
  )
  writeJson(response, 201, worktree)
  return true
}

export interface WorktreeServices {
  readonly services: CodevisorServerServices
  readonly config: CodevisorServerConfig
  readonly fanout: EventFanout
  readonly serverId: string
}

export interface AllocatedWorktree {
  readonly worktree: Worktree
  readonly rollBack: () => Promise<void>
}

export const allocateProjectWorktree = async (
  { services, config, fanout, serverId }: WorktreeServices,
  worktreeProjectId: string,
  payload: CreateWorktreeRequest
): Promise<AllocatedWorktree> => {
  const project = await getProjectOrFail(services.db, worktreeProjectId)
  const location = worktreeableLocation(serverId, project)
  if (!(await isGitWorkTree(location.folderPath))) throw notAGitRepository(location.folderPath)

  const existing = worktreeNameSet(await run(services.db.listWorktrees(project.id)))
  addNames(existing, await listCodevisorWorktreeBranchNames(location.folderPath))
  addNames(existing, await listRemoteCodevisorBranchNames(location.folderPath))
  const requested = slugifyWorktreeName(payload.name)

  const environment = await locationGitEnvironment(services, location)
  const startPoint = await worktreeStartPoint(
    location.folderPath,
    project.worktreeBase,
    environment
  )
  const worktree = await addUnusedWorktree({
    services,
    config,
    fanout,
    payload,
    project,
    location,
    existing,
    requested,
    environment,
    startPoint
  })
  return {
    worktree,
    rollBack: () => rollBackNewWorktree(services, location.folderPath, worktree, environment)
  }
}

const rollBackNewWorktree = async (
  services: CodevisorServerServices,
  repoDir: string,
  worktree: Worktree,
  environment: NodeJS.ProcessEnv
): Promise<void> => {
  const removed = await rollbackFailedWorktree(repoDir, worktree.path, worktree.branch, environment)
  if (!removed) {
    throw new Error(
      `Left worktree ${worktree.name} in place: its checkout no longer matches the one this start created`
    )
  }
  await run(services.db.deleteWorktree(worktree.id))
}

export const slugifyWorktreeName = (name: string | undefined): string | undefined => {
  const slug = (name ?? "")
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "")
    .slice(0, 64)
    .replace(/-+$/g, "")
  return slug.length > 0 ? slug : undefined
}

export const availableWorktreeName = (base: string, existing: ReadonlySet<string>): string => {
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
  /* v8 ignore next */
  throw new Error("Unable to allocate a unique worktree name")
}

interface WorktreeAllocation {
  readonly services: CodevisorServerServices
  readonly config: CodevisorServerConfig
  readonly fanout: EventFanout
  readonly payload: CreateWorktreeRequest
  readonly project: Project
  readonly location: ProjectLocation
  readonly existing: Set<string>
  readonly requested: string | undefined
  readonly environment: NodeJS.ProcessEnv
  readonly startPoint: string | undefined
}

interface WorktreeSetup {
  readonly worktree: Worktree
  readonly branch: string
  readonly startedAt: number
  readonly publish: WorktreeSetupPublisher
}

const maxWorktreeAttempts = 100
const lastWorktreeAttempt = maxWorktreeAttempts - 1

const worktreeableLocation = (serverId: string, project: Project): ProjectLocation => {
  const location = localLocationOrFail(serverId, project)
  assertLocationFolderExists(location)
  if (isScratchProject(project)) {
    throw new HttpFailure(422, "A scratch workspace folder cannot have worktrees")
  }
  return location
}

const notAGitRepository = (folderPath: string): HttpFailure =>
  new HttpFailure(422, `Project folder is not a git repository: ${folderPath}`)

const worktreeNameSet = (worktrees: ReadonlyArray<Worktree>): Set<string> =>
  new Set(worktrees.map((worktree) => worktree.name))

const addNames = (names: Set<string>, more: Iterable<string>): void => {
  for (const name of more) {
    names.add(name)
  }
}

const locationGitEnvironment = (
  services: CodevisorServerServices,
  location: ProjectLocation
): Promise<NodeJS.ProcessEnv> =>
  services.resolveGitEnvironment?.(location.folderPath) ?? Promise.resolve(process.env)

const addUnusedWorktree = async (allocation: WorktreeAllocation): Promise<Worktree> => {
  const { services, config, fanout, payload, project, location, existing } = allocation
  const { requested, environment, startPoint } = allocation
  for (let attempt = 0; attempt < maxWorktreeAttempts; attempt += 1) {
    const name = nextWorktreeName(config, requested, existing)
    const branch = `codevisor/${name}`
    let worktree: Worktree
    try {
      worktree = await run(services.db.createWorktree(project.id, name, branch, payload.id))
    } catch (cause) {
      /* v8 ignore start */
      if (isWorktreeNameCollision(cause) && attempt < lastWorktreeAttempt) {
        existing.add(name)
        continue
      }
      throw cause
      /* v8 ignore stop */
    }
    const setup = beginWorktreeSetup(allocation, worktree, branch)
    await setup.publish({ state: "started" })
    try {
      mkdirSync(dirname(worktree.path), { recursive: true })
      await addWorktree(
        location.folderPath,
        worktree.path,
        branch,
        worktreeLogPublisher(setup.publish),
        startPoint,
        environment
      )
      await setup.publish({ state: "completed", durationMs: Date.now() - setup.startedAt })
    } catch (cause) {
      /* v8 ignore start */
      await run(services.db.deleteWorktree(worktree.id)).catch(() => undefined)
      if (isWorktreeBranchCollision(cause) && attempt < lastWorktreeAttempt) {
        existing.add(name)
        await setup.publish({
          state: "log",
          stream: "stderr",
          line: `Branch ${branch} was claimed concurrently; choosing another name.`
        })
        continue
      }
      return abandonWorktree(allocation, setup, cause)
      /* v8 ignore stop */
    }
    await appendAndPublish(services.db, fanout, "worktree.created", worktree.id, worktree)
    return worktree
  }
  /* v8 ignore next */
  throw new HttpFailure(422, "Unable to allocate an unused Git worktree branch")
}

const nextWorktreeName = (
  config: CodevisorServerConfig,
  requested: string | undefined,
  existing: ReadonlySet<string>
): string => {
  if (config.worktreeNameStyle === "development") return availableDevelopmentWorktreeName(existing)
  if (requested === undefined) return availableProductionWorktreeName(existing)
  return availableWorktreeName(requested, existing)
}

const beginWorktreeSetup = (
  allocation: WorktreeAllocation,
  worktree: Worktree,
  branch: string
): WorktreeSetup => {
  const startedAt = Date.now()
  const publish = makeWorktreeSetupPublisher(
    allocation.services.db,
    allocation.fanout,
    worktree,
    allocation.payload.sessionId
  )
  return { worktree, branch, startedAt, publish }
}

const worktreeLogPublisher =
  (publish: WorktreeSetupPublisher) =>
  (stream: "stdout" | "stderr", line: string): void => {
    void publish({ state: "log", stream, line }).catch(swallowError)
  }

/* v8 ignore start */
const abandonWorktree = async (
  allocation: WorktreeAllocation,
  setup: WorktreeSetup,
  cause: unknown
): Promise<never> => {
  try {
    const removed = await rollbackFailedWorktree(
      allocation.location.folderPath,
      setup.worktree.path,
      setup.branch,
      allocation.environment
    )
    if (removed) {
      await setup.publish({
        state: "log",
        stream: "stderr",
        line: "Removed the partial worktree and branch."
      })
    }
  } catch (cleanupCause) {
    await setup.publish({
      state: "log",
      stream: "stderr",
      line: `Could not fully remove the partial worktree: ${failureMessage(cleanupCause)}`
    })
  }
  await setup.publish({
    state: "failed",
    message: failureMessage(cause),
    durationMs: Date.now() - setup.startedAt
  })
  throw cause
}
/* v8 ignore stop */

/* v8 ignore start */
const isWorktreeNameCollision = (cause: unknown): boolean => {
  if (!(cause instanceof DatabaseError)) return false
  if (cause.operation !== "createWorktree") return false
  return cause.message.includes(
    "UNIQUE constraint failed: worktrees.project_id, worktrees.server_id, worktrees.name"
  )
}
/* v8 ignore stop */

type WorktreeSetupDetail = Omit<WorktreeSetupUpdate, "worktreeId" | "projectId" | "name" | "branch">

type WorktreeSetupPublisher = (detail: WorktreeSetupDetail) => Promise<void>

const makeWorktreeSetupPublisher = (
  db: CodevisorDatabaseService,
  fanout: EventFanout,
  worktree: Worktree,
  mirrorSubjectId?: string
): WorktreeSetupPublisher => {
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
    /* v8 ignore next */
    chain = next.catch(() => undefined)
    return next
  }
}
