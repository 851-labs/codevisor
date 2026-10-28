import type { AgentProjectSource, Project, StartAgentRequest } from "@codevisor/api"

import { HttpFailure, run } from "../server-context.js"
import { setUpProjectFromGit } from "./project-clone.js"
import type { RouteContext } from "./route-context.js"

export const agentProjectId = async (
  route: RouteContext,
  request: StartAgentRequest,
  callerProjectId: string | undefined
): Promise<string> => {
  if (request.project === undefined && callerProjectId !== undefined) return callerProjectId
  const projects = await run(route.services.db.listProjects)
  const found = projects.find((candidate) => matchesProject(candidate, request.project))
  if (found !== undefined) return found.id

  const source = request.callerDefaults?.project
  if (source === undefined) throw new HttpFailure(422, projectHint(request.project, projects))
  return clonedProjectId(route, source)
}

const matchesProject = (project: Project, wanted: string | undefined): boolean => {
  const key = wanted?.toLowerCase()
  return project.id.toLowerCase() === key || project.name.toLowerCase() === key
}

const clonedProjectId = async (
  route: RouteContext,
  source: AgentProjectSource
): Promise<string> => {
  const { services, fanout, config } = route
  const setUp = await setUpProjectFromGit(
    { services, fanout, serverId: config.id },
    { url: source.repoUrl, name: source.name }
  )
  return setUp.project.id
}

const projectHint = (project: string | undefined, projects: ReadonlyArray<Project>): string => {
  const names = projects.map((candidate) => `${candidate.name} (${candidate.id})`).join(", ")
  if (project === undefined)
    return `Pass project: an id or name. Projects on this machine: ${names}`
  return `No project matches "${project}". Projects on this machine: ${names}`
}
