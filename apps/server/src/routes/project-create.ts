import type { CreateProjectRequest, Project } from "@codevisor/api"

import {
  appendAndPublish,
  existingDirectory,
  run,
  type CodevisorServerServices,
  type EventFanout
} from "../server-context.js"
import { discoverRepoUrl } from "./project-repo-identity.js"

export const addProject = async (
  services: CodevisorServerServices,
  fanout: EventFanout,
  request: CreateProjectRequest
): Promise<Project> => {
  const repoUrl = request.repoUrl ?? (await folderRepoUrl(services, request.folderPath))
  const project = await run(
    services.db.createProject({
      ...request,
      ...(repoUrl === undefined ? {} : { repoUrl })
    })
  )
  await appendAndPublish(services.db, fanout, "project.created", project.id, project)
  return project
}

const folderRepoUrl = async (
  services: CodevisorServerServices,
  folderPath: string
): Promise<string | undefined> => {
  if (existingDirectory(folderPath) === undefined) return undefined
  return discoverRepoUrl(
    folderPath,
    await (services.resolveGitEnvironment?.() ?? Promise.resolve(process.env))
  )
}
