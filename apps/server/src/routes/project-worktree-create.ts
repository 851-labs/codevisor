import { mkdirSync } from "node:fs"
import type { IncomingMessage, ServerResponse } from "node:http"
import { dirname } from "node:path"

import type { Worktree, WorktreeSetupUpdate } from "@codevisor/api"
import { CreateWorktreeRequest as CreateWorktreeRequestSchema } from "@codevisor/api"
import { DatabaseError, type CodevisorDatabaseService } from "@codevisor/db"
import {
  addWorktree,
  isGitWorkTree,
  isWorktreeBranchCollision,
  listCodevisorWorktreeBranchNames,
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
  const project = await getProjectOrFail(services.db, worktreeProjectId)
  const location = localLocationOrFail(serverId, project)
  assertLocationFolderExists(location)
  if (isScratchProject(project)) {
    throw new HttpFailure(422, "A scratch workspace folder cannot have worktrees")
  }
  if (!(await isGitWorkTree(location.folderPath))) {
    throw new HttpFailure(422, `Project folder is not a git repository: ${location.folderPath}`)
  }
  const existing = new Set((await run(services.db.listWorktrees(project.id))).map((w) => w.name))
  for (const name of await listCodevisorWorktreeBranchNames(location.folderPath)) {
    existing.add(name)
  }
  const requested = slugifyWorktreeName(payload.name)
  const environment = await (services.resolveGitEnvironment?.(location.folderPath) ??
    Promise.resolve(process.env))
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
      /* v8 ignore start */
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
      /* v8 ignore start */
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
        if (await rollbackFailedWorktree(location.folderPath, worktree.path, branch, environment)) {
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
  /* v8 ignore next */
  throw new HttpFailure(422, "Unable to allocate an unused Git worktree branch")
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
  /* v8 ignore next */
  throw new Error("Unable to allocate a unique worktree name")
}

/* v8 ignore start */
const isWorktreeNameCollision = (cause: unknown): boolean =>
  cause instanceof DatabaseError &&
  cause.operation === "createWorktree" &&
  cause.message.includes(
    "UNIQUE constraint failed: worktrees.project_id, worktrees.server_id, worktrees.name"
  )
/* v8 ignore stop */

type WorktreeSetupDetail = Omit<WorktreeSetupUpdate, "worktreeId" | "projectId" | "name" | "branch">

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
    /* v8 ignore next */
    chain = next.catch(() => undefined)
    return next
  }
}
