import { randomUUID } from "node:crypto"
import { existsSync, mkdirSync, rmSync } from "node:fs"
import type { IncomingMessage, ServerResponse } from "node:http"
import { dirname } from "node:path"

import type { ProjectSetupUpdate } from "@codevisor/api"
import { CreateProjectFromGitRequest as CreateProjectFromGitRequestSchema } from "@codevisor/api"
import { managedRepoPath, type CodevisorDatabaseService } from "@codevisor/db"
import { CloneError, cloneRepository } from "@codevisor/worktrees"

import {
  appendAndPublish,
  failureMessage,
  HttpFailure,
  readSchema,
  run,
  swallowError,
  writeJson,
  type CodevisorServerServices,
  type EventFanout
} from "../server-context.js"
import { cloneDirectoryName, looksLikeGitUrl } from "./project-git-url.js"
import { probeProject } from "./project-probe.js"

export const routeProjectFromGit = async (
  services: CodevisorServerServices,
  fanout: EventFanout,
  serverId: string,
  request: IncomingMessage,
  response: ServerResponse
): Promise<void> => {
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
    /* v8 ignore next */
    const code = cause instanceof CloneError ? cause.code : undefined
    await publishSetup({
      state: "failed",
      message: failureMessage(cause),
      /* v8 ignore next */
      ...(code === undefined ? {} : { code }),
      durationMs: Date.now() - startedAt
    })
    /* v8 ignore next */
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
}

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
    /* v8 ignore next */
    chain = next.catch(() => undefined)
    return next
  }
}
