import type { BackgroundTaskOutput } from "@codevisor/api"

import { HttpFailure, matchRouteParams, run, writeJson } from "../server-context.js"
import type { CodevisorServerServices } from "../server-context.js"
import type { RouteContext } from "./route-context.js"
import { routeParam } from "./route-params.js"
import { isRuntimeLoaded } from "./runtime-loaded.js"
import { findSession } from "./session-workspace.js"

const outputLineLimit = 50

interface TaskRoute {
  readonly agentSessionId: string
  readonly taskId: string
}

export const routeSessionTasks = (route: RouteContext): Promise<boolean> | undefined => {
  const { request, url } = route
  const stopParams = matchRouteParams(url.pathname, "/v1/sessions/:id/tasks/:taskId/stop")
  if (stopParams !== undefined && request.method === "POST") return stopTask(route, stopParams)

  const outputParams = matchRouteParams(url.pathname, "/v1/sessions/:id/tasks/:taskId/output")
  if (outputParams !== undefined && request.method === "GET")
    return readTaskOutput(route, outputParams)

  return undefined
}

const stopTask = async (
  { services, response }: RouteContext,
  params: Record<string, string>
): Promise<boolean> => {
  const task = await loadedTask(services, params)
  const stopped = await run(services.agents.stopTask(task.agentSessionId, task.taskId))
  if (!stopped) throw new HttpFailure(409, "This harness can't stop a single task")

  writeJson(response, 204, undefined)
  return true
}

const readTaskOutput = async (
  { services, response }: RouteContext,
  params: Record<string, string>
): Promise<boolean> => {
  const task = await loadedTask(services, params)
  const lines = await run(
    services.agents.readTaskOutput(task.agentSessionId, task.taskId, outputLineLimit)
  )
  if (lines === undefined) throw new HttpFailure(404, "This task's output isn't available")

  const body: BackgroundTaskOutput = { lines }
  writeJson(response, 200, body)
  return true
}

const loadedTask = async (
  services: CodevisorServerServices,
  params: Record<string, string>
): Promise<TaskRoute> => {
  const session = await findSession(services.db, routeParam(params, "id"))
  if (session === undefined) throw new HttpFailure(404, "Session not found")
  if (!isRuntimeLoaded(services, session.agentSessionId)) {
    throw new HttpFailure(409, "The session's agent isn't running")
  }

  return { agentSessionId: session.agentSessionId, taskId: routeParam(params, "taskId") }
}
