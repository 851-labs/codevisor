import type { AgentProjectSource, Project, StartAgentRequest } from "@codevisor/api"

import { HttpFailure, run } from "../server-context.js"
import { setUpProjectFromGit } from "./project-clone.js"
import { isBotProject, isScratchProject } from "./project-probe.js"
import { newScratchProject } from "./project-scratch.js"
import type { RouteContext } from "./route-context.js"

export const agentProjectId = async (
  route: RouteContext,
  request: StartAgentRequest,
  callerProjectId: string | undefined,
  created: Array<() => Promise<unknown>>
): Promise<string> => {
  if (request.noProject === true) return scratchProjectId(route, request, created)
  if (request.project === undefined && callerProjectId !== undefined) return callerProjectId
  const projects = await run(route.services.db.listProjects)
  const found = projects.find((candidate) => matchesProject(candidate, request.project))
  if (found !== undefined) return found.id

  const source = request.callerDefaults?.project
  if (source === undefined) throw new HttpFailure(422, projectHint(request.project, projects))
  return clonedProjectId(route, source)
}

const scratchProjectId = async (
  route: RouteContext,
  request: StartAgentRequest,
  created: Array<() => Promise<unknown>>
): Promise<string> => {
  assertNoProjectFits(request)
  const scratch = await newScratchProject(route)
  created.push(scratch.rollBack)
  return scratch.project.id
}

const assertNoProjectFits = (request: StartAgentRequest): void => {
  if (request.project !== undefined) {
    throw new HttpFailure(422, "Pass either project or noProject: true, not both")
  }
  if (request.sandboxProfile !== undefined) {
    throw new HttpFailure(422, "noProject: true starts the agent on a machine, not on a sandbox")
  }
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

const noProjectOption = "or noProject: true for a chat in a fresh empty folder with no project"

const projectHint = (project: string | undefined, projects: ReadonlyArray<Project>): string => {
  const known = `Projects on this machine: ${projectNames(projects)}`
  if (project === undefined) return `Pass project (an id or name), ${noProjectOption}. ${known}`
  return `No project matches "${project}". Pass an id or name, ${noProjectOption}. ${known}`
}

const projectNames = (projects: ReadonlyArray<Project>): string => {
  const listed = projects.filter(isSidebarProject)
  if (listed.length === 0) return "none"
  return listed.map((candidate) => `${candidate.name} (${candidate.id})`).join(", ")
}

const isSidebarProject = (project: Project): boolean =>
  !isScratchProject(project) && !isBotProject(project)
