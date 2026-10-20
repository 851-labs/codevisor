import { mkdirSync, readdirSync } from "node:fs"
import type { IncomingMessage, ServerResponse } from "node:http"

import { CreateScratchProjectRequest as CreateScratchProjectRequestSchema } from "@codevisor/api"
import {
  legacyScratchWorkspacesRoot,
  scratchWorkspacePath,
  scratchWorkspacesRoot
} from "@codevisor/db"
import {
  availableDevelopmentWorktreeName,
  availableProductionWorktreeName
} from "@codevisor/worktrees"

import {
  appendAndPublish,
  HttpFailure,
  readSchema,
  run,
  writeJson,
  type CodevisorServerConfig,
  type CodevisorServerServices,
  type EventFanout
} from "../server-context.js"
import { probeProject } from "./project-probe.js"

const allocateScratchWorkspaceFolder = (config: CodevisorServerConfig): string => {
  mkdirSync(scratchWorkspacesRoot(), { recursive: true })
  let legacyFolders: ReadonlyArray<string> = []
  try {
    legacyFolders = readdirSync(legacyScratchWorkspacesRoot())
  } catch {}
  const taken = new Set([...readdirSync(scratchWorkspacesRoot()), ...legacyFolders])
  for (let attempt = 0; attempt < 100; attempt += 1) {
    const candidate =
      config.worktreeNameStyle === "development"
        ? availableDevelopmentWorktreeName(taken)
        : availableProductionWorktreeName(taken)
    try {
      mkdirSync(scratchWorkspacePath(candidate))
      return candidate
    } catch {
      /* v8 ignore next */
      taken.add(candidate)
    }
  }
  /* v8 ignore next 3 */
  throw new HttpFailure(500, "Could not allocate a scratch workspace folder")
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
  if (existing === undefined) return false
  writeJson(response, 200, await probeProject(serverId, existing))
  return true
}

export const createScratchProject = async (
  services: CodevisorServerServices,
  config: CodevisorServerConfig,
  fanout: EventFanout,
  serverId: string,
  request: IncomingMessage,
  response: ServerResponse
): Promise<boolean> => {
  const payload = await readSchema(request, CreateScratchProjectRequestSchema)
  const requestedId = payload.id
  if (
    requestedId !== undefined &&
    (await writeExistingScratchProject(services, serverId, requestedId, response))
  )
    return true
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
