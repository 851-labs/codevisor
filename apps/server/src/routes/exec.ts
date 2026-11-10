import { stat } from "node:fs/promises"
import { homedir } from "node:os"

import {
  EXEC_DEFAULT_TIMEOUT_MS,
  EXEC_MAX_TIMEOUT_MS,
  ExecRequest,
  FLEET_EXEC_TASK_PATH,
  parseRemoteSessionKey,
  type ExecTaskEvent
} from "@codevisor/api"

import type { ExecCommand, ExecTasks, FinishedExecTask } from "../infra/exec-tasks.js"
import { HttpFailure, matchRoute, readSchema, swallowError, writeJson } from "../server-context.js"
import { expandFsPath } from "./fs-paths.js"
import type { RouteContext } from "./route-context.js"

export const routeExec = async (route: RouteContext): Promise<boolean> => {
  const { request, url } = route
  if (!url.pathname.startsWith("/v1/exec")) return false
  const tasks = requireExecTasks(route)

  if (url.pathname === "/v1/exec" && request.method === "POST") return exec(route, tasks)
  if (url.pathname === "/v1/exec/activity" && request.method === "GET")
    return writeActivity(route, tasks)
  const taskId = matchRoute(url.pathname, "/v1/exec/tasks/:taskId")
  if (taskId !== undefined && request.method === "GET") return writeTask(route, tasks.get(taskId))
  const stopping = matchRoute(url.pathname, "/v1/exec/tasks/:taskId/stop")
  if (stopping !== undefined && request.method === "POST")
    return writeTask(route, await tasks.stop(stopping))
  return false
}

const requireExecTasks = (route: RouteContext): ExecTasks => {
  const tasks = route.services.execTasks
  if (tasks === undefined) throw new HttpFailure(501, "Running commands isn't available here")
  return tasks
}

const exec = async (route: RouteContext, tasks: ExecTasks): Promise<boolean> => {
  const body = await readSchema(route.request, ExecRequest)
  const command = await execCommand(body)

  if (body.run_in_background !== true) {
    writeJson(route.response, 200, await tasks.run(command))
    return true
  }
  const task = tasks.start(command, (finished) => announceTask(route, body, finished))
  announceTask(route, body, { task, outputTail: "" })
  writeJson(route.response, 200, { taskId: task.taskId, outputPath: task.outputPath })
  return true
}

const execCommand = async (body: ExecRequest): Promise<ExecCommand> => {
  if (body.command.trim() === "") throw new HttpFailure(400, "command is empty", "invalid_command")
  return {
    command: body.command,
    description: body.description ?? body.command.slice(0, 80),
    cwd: await workingDirectory(body.cwd),
    timeoutMs: clampedTimeout(body.timeout),
    ...ownerOf(body)
  }
}

const ownerOf = (body: ExecRequest): { readonly owner?: string } => {
  const remote =
    body.callerAgentId === undefined ? undefined : parseRemoteSessionKey(body.callerAgentId)
  return remote === undefined ? {} : { owner: remote.machineId }
}

const workingDirectory = async (requested: string | undefined): Promise<string> => {
  if (requested === undefined) return homedir()
  const path = expandFsPath(requested)
  const info = await stat(path).catch(() => undefined)
  if (info?.isDirectory() !== true) {
    throw new HttpFailure(400, `No such directory: ${path}`, "invalid_cwd")
  }
  return path
}

const clampedTimeout = (requested: number | undefined): number => {
  if (requested === undefined || !Number.isFinite(requested) || requested <= 0)
    return EXEC_DEFAULT_TIMEOUT_MS
  return Math.min(requested, EXEC_MAX_TIMEOUT_MS)
}

const writeActivity = (route: RouteContext, tasks: ExecTasks): boolean => {
  const { running, lastActiveAt } = tasks.activity()
  writeJson(route.response, 200, {
    running,
    ...(lastActiveAt === undefined ? {} : { lastActiveAt: lastActiveAt.toISOString() })
  })
  return true
}

const writeTask = (route: RouteContext, task: unknown): boolean => {
  if (task === undefined) throw new HttpFailure(404, "No such task on this machine", "not_found")
  writeJson(route.response, 200, task)
  return true
}

const announceTask = (route: RouteContext, body: ExecRequest, finished: FinishedExecTask): void => {
  const caller = body.callerAgentId
  if (caller === undefined) return

  const remote = parseRemoteSessionKey(caller)
  const self = { id: route.config.id, name: route.config.name }
  const event: ExecTaskEvent = { sessionId: remote?.sessionId ?? caller, ...finished }
  if (remote === undefined) {
    route.routeState.announceExecTask?.(event, self)
    return
  }
  void route.services.machines
    ?.invoke(remote.machineId, FLEET_EXEC_TASK_PATH, event, {
      machineId: self.id,
      machineName: self.name
    })
    .catch(swallowError)
}
