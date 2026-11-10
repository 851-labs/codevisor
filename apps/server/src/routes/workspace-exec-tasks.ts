import type { RemoteExecTask } from "@codevisor/api"

import type { RemoteExecTasks } from "../infra/remote-exec-tasks.js"
import { HttpFailure, matchRouteParams, writeJson } from "../server-context.js"
import { workspaceExecTasks } from "../workspace-exec-tasks.js"
import type { RouteContext } from "./route-context.js"

export const EXEC_OUTPUT_LINES = 50

export const routeWorkspaceExecTasks = async (route: RouteContext): Promise<boolean> => {
  const { request, url } = route
  const list = matchRouteParams(url.pathname, "/v1/workspaces/:id/exec-tasks")
  if (list?.id !== undefined && request.method === "GET") return listTasks(route, list.id)

  const stop = matchRouteParams(url.pathname, "/v1/workspaces/:id/exec-tasks/:taskId/stop")
  if (stop?.taskId !== undefined && request.method === "POST") return stopTask(route, stop.taskId)

  const output = matchRouteParams(url.pathname, "/v1/workspaces/:id/exec-tasks/:taskId/output")
  if (output?.taskId !== undefined && request.method === "GET")
    return readOutput(route, output.taskId)
  return false
}

const registry = (route: RouteContext): RemoteExecTasks => {
  const tasks = route.services.remoteExecTasks
  if (tasks === undefined) throw new HttpFailure(501, "Background commands aren't tracked here")
  return tasks
}

const listTasks = async (route: RouteContext, workspaceId: string): Promise<boolean> => {
  registry(route)
  writeJson(route.response, 200, { items: await workspaceExecTasks(route.services, workspaceId) })
  return true
}

const stopTask = async (route: RouteContext, taskId: string): Promise<boolean> => {
  await registry(route).stop(requireTask(route, taskId))
  writeJson(route.response, 204, undefined)
  return true
}

const readOutput = async (route: RouteContext, taskId: string): Promise<boolean> => {
  const task = requireTask(route, taskId)
  const lines = await registry(route).control(task, {
    action: "output",
    taskId,
    lines: EXEC_OUTPUT_LINES
  })
  writeJson(route.response, 200, { lines: Array.isArray(lines) ? lines : [] })
  return true
}

const requireTask = (route: RouteContext, taskId: string): RemoteExecTask => {
  const task = registry(route).find(taskId)
  if (task === undefined) throw new HttpFailure(404, "No such background command", "not_found")
  return task
}
