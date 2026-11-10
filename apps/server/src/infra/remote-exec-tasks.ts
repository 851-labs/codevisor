import {
  FLEET_EXEC_CONTROL_PATH,
  type ExecTaskEvent,
  type FleetExecControl,
  type RemoteExecTask
} from "@codevisor/api"

import type { ExecTasks } from "./exec-tasks.js"
import type { MirrorTransportSelf } from "./fleet-mirror-transport.js"
import type { MachineLink } from "./machine-link.js"

export interface ExecTaskMachine {
  readonly id: string
  readonly name: string
}

export interface RemoteExecTasks {
  readonly record: (event: ExecTaskEvent, machine: ExecTaskMachine) => void
  readonly list: () => ReadonlyArray<RemoteExecTask>
  readonly find: (taskId: string) => RemoteExecTask | undefined
  readonly control: (task: RemoteExecTask, action: FleetExecControl) => Promise<unknown>
  readonly stop: (task: RemoteExecTask) => Promise<void>
  readonly forget: (taskId: string) => void
}

export interface RemoteExecTasksOptions {
  readonly self: MirrorTransportSelf
  readonly link: Pick<MachineLink, "invoke">
  readonly local: ExecTasks
}

export const makeRemoteExecTasks = (options: RemoteExecTasksOptions): RemoteExecTasks => {
  const tasks = new Map<string, RemoteExecTask>()

  const control = (task: RemoteExecTask, action: FleetExecControl): Promise<unknown> => {
    if (task.machine.machineId === options.self.id) return runExecControl(options.local, action)
    return options.link.invoke(task.machine.machineId, FLEET_EXEC_CONTROL_PATH, action, {
      machineId: options.self.id,
      machineName: options.self.name()
    })
  }

  return {
    record: (event, machine) => {
      if (event.task.state !== "running") {
        tasks.delete(event.task.taskId)
        return
      }
      tasks.set(event.task.taskId, runningTask(event, machine))
    },
    list: () => [...tasks.values()],
    find: (taskId) => tasks.get(taskId),
    control,
    stop: async (task) => {
      await control(task, { action: "stop", taskId: task.taskId })
      tasks.delete(task.taskId)
    },
    forget: (taskId) => {
      tasks.delete(taskId)
    }
  }
}

export const runExecControl = async (
  tasks: ExecTasks,
  control: FleetExecControl
): Promise<unknown> => {
  if (control.action === "stop") return (await tasks.stop(control.taskId)) ?? null
  return (await tasks.readTail(control.taskId, control.lines)) ?? []
}

const runningTask = (event: ExecTaskEvent, machine: ExecTaskMachine): RemoteExecTask => ({
  taskId: event.task.taskId,
  sessionId: event.sessionId,
  machine: { machineId: machine.id, name: machine.name },
  description: event.task.description,
  command: event.task.command,
  startedAt: event.task.startedAt,
  outputPath: event.task.outputPath
})
