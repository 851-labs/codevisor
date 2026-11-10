import type { RemoteExecTask } from "@codevisor/api"

import type { CodevisorServerServices } from "./server-context-types.js"
import { run } from "./server-http.js"

export const workspaceExecTasks = async (
  services: CodevisorServerServices,
  workspaceId: string
): Promise<ReadonlyArray<RemoteExecTask>> => {
  const owned: RemoteExecTask[] = []
  for (const task of services.remoteExecTasks?.list() ?? []) {
    if (await belongsTo(services, task, workspaceId)) owned.push(task)
  }
  return owned
}

export const stopWorkspaceExecTasks = async (
  services: CodevisorServerServices,
  workspaceId: string
): Promise<void> => {
  const registry = services.remoteExecTasks
  if (registry === undefined) return
  const tasks = await workspaceExecTasks(services, workspaceId)
  await Promise.allSettled(tasks.map((task) => registry.stop(task)))
}

const belongsTo = async (
  services: CodevisorServerServices,
  task: RemoteExecTask,
  workspaceId: string
): Promise<boolean> => {
  const session = await run(services.db.getSessionSummary(task.sessionId)).catch(() => undefined)
  return session?.workspaceId?.toLowerCase() === workspaceId.toLowerCase()
}
