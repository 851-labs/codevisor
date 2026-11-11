import { CreateExternalGatewayRequest, type Project } from "@codevisor/api"
import type { McpManager } from "@codevisor/mcp"

import { HttpFailure, readSchema, run, writeJson } from "../server-context.js"
import { isMethodRoute, type RouteContext } from "./route-context.js"

const defaultClientName = "an MCP client"

export const routeMcpGateways = async (route: RouteContext): Promise<boolean> => {
  const { request, url } = route
  if (!isMethodRoute(request, url, "POST", "/v1/mcp-gateways")) return false
  const manager = requireGateway(route)

  const body = await readSchema(request, CreateExternalGatewayRequest)
  const projectId = await projectIdFor(route, body.project)
  const issued = await manager.issueExternalGateway({
    client: { name: clientName(body.clientName) },
    projectId
  })
  writeJson(route.response, 201, { url: issued.url, bearerToken: issued.bearerToken })
  return true
}

const requireGateway = ({ services }: RouteContext): McpManager => {
  if (services.mcp === undefined) throw new HttpFailure(501, "MCP gateway unavailable")
  return services.mcp
}

const clientName = (requested: string | undefined): string => {
  const trimmed = requested?.trim() ?? ""
  return trimmed === "" ? defaultClientName : trimmed
}

const projectIdFor = async (
  { services }: RouteContext,
  wanted: string | undefined
): Promise<string | undefined> => {
  if (wanted === undefined) return undefined

  const projects = await run(services.db.listProjects)
  const found = projects.find((project) => matchesProject(project, wanted))
  if (found === undefined) throw new HttpFailure(404, unknownProject(wanted, projects))
  return found.id
}

const matchesProject = (project: Project, wanted: string): boolean => {
  const key = wanted.toLowerCase()
  return project.id.toLowerCase() === key || project.name.toLowerCase() === key
}

const unknownProject = (wanted: string, projects: ReadonlyArray<Project>): string => {
  const names = projects.map((project) => project.name).toSorted((a, b) => a.localeCompare(b))
  if (names.length === 0) return `No project named ${wanted}: this machine has no projects`
  return `No project named ${wanted}. Projects: ${names.join(", ")}`
}
