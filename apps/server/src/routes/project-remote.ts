import type { IncomingMessage, ServerResponse } from "node:http"

import { PublishProjectRemoteRequest as PublishProjectRemoteRequestSchema } from "@codevisor/api"
import { publishToRemote } from "@codevisor/worktrees"

import {
  appendAndPublish,
  HttpFailure,
  readSchema,
  run,
  writeJson,
  type CodevisorServerServices,
  type EventFanout
} from "../server-context.js"
import { looksLikeGitUrl } from "./project-git-url.js"
import { probeProject } from "./project-probe.js"
import { gitEnvironment, localFolderOrFail } from "./project-setup-source.js"

const firstLine = (message: string): string => message.trim().replace(/\n[\s\S]*$/, "")

export const routePublishProjectRemote = async (
  services: CodevisorServerServices,
  fanout: EventFanout,
  serverId: string,
  projectId: string,
  request: IncomingMessage,
  response: ServerResponse
): Promise<void> => {
  const payload = await readSchema(request, PublishProjectRemoteRequestSchema)
  const url = payload.url.trim()
  if (!looksLikeGitUrl(url)) {
    throw new HttpFailure(400, `Not a git URL: ${payload.url}`, "invalid_url")
  }
  const { project, location, folderPath } = await localFolderOrFail(services, serverId, projectId)
  if (project.repoUrl !== undefined) {
    throw new HttpFailure(409, "This project already has a remote", "already_exists")
  }
  await publishToRemote(folderPath, url, {
    initialize: payload.initialize === true,
    env: await gitEnvironment(services)
  }).catch((cause: Error & { readonly code?: string }) => {
    throw new HttpFailure(422, firstLine(cause.message), cause.code)
  })
  await run(services.db.setProjectLocationGitState(location.id, true))
  const updated = await run(services.db.setProjectRepoUrl(project.id, url))
  const probed = await probeProject(serverId, updated)
  await appendAndPublish(services.db, fanout, "project.updated", probed.id, probed)
  writeJson(response, 200, probed)
}
