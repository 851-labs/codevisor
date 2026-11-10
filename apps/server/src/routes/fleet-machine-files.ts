import {
  decode,
  ExecTaskEvent,
  FleetExecControl,
  FleetMirrorAction,
  type ExecTaskEvent as ExecTaskEventType
} from "@codevisor/api"

import type { MirrorStore } from "../infra/mirror-store.js"
import { runExecControl } from "../infra/remote-exec-tasks.js"
import { HttpFailure, type CodevisorServerServices, type RouteState } from "../server-context.js"
import type { FleetCall } from "./fleet-calls.js"

export const receiveMirrorAction = async (
  services: CodevisorServerServices,
  call: FleetCall,
  args: unknown
): Promise<unknown> => {
  if (!call.verified) throw new HttpFailure(403, "Only machines on this account can sync here")
  const mirrors = services.mirrors
  if (mirrors === undefined) throw new HttpFailure(501, "Workspace mirrors aren't available here")
  return runMirrorAction(mirrors, decodeMirrorAction(args), call.origin.machineId)
}

export const receiveExecTask = (
  routeState: RouteState,
  call: FleetCall,
  args: unknown
): boolean => {
  if (!call.verified) throw new HttpFailure(403, "Only machines on this account can send events")
  const event = decodeExecTask(args)
  const machine = { id: call.origin.machineId, name: call.origin.machineName }
  routeState.announceExecTask?.(event, machine)
  return true
}

export const receiveExecControl = (
  services: CodevisorServerServices,
  call: FleetCall,
  args: unknown
): Promise<unknown> => {
  if (!call.verified) throw new HttpFailure(403, "Only machines on this account can do that")
  return execControl(services, decodeExecControl(args))
}

const execControl = (
  services: CodevisorServerServices,
  control: FleetExecControl
): Promise<unknown> => {
  const tasks = services.execTasks
  if (tasks === undefined) throw new HttpFailure(501, "Running commands isn't available here")
  return runExecControl(tasks, control)
}

const decodeExecControl = (args: unknown): FleetExecControl => {
  try {
    return decode(FleetExecControl)(args)
  } catch {
    throw new HttpFailure(400, "Expected { action, taskId }")
  }
}

const runMirrorAction = async (
  mirrors: MirrorStore,
  action: FleetMirrorAction,
  owner: string
): Promise<unknown> => {
  if (action.action === "prepare") return mirrors.prepare(action.mirrorId, action.name, owner)
  if (action.action === "apply") return mirrors.apply(action.mirrorId, action.commit, action.head)
  if (action.action === "write") {
    await mirrors.write(action.mirrorId, action.offset, Buffer.from(action.data, "base64"))
    return { written: true }
  }
  await mirrors.remove(action.mirrorId)
  return { removed: true }
}

const decodeMirrorAction = (args: unknown): FleetMirrorAction => {
  try {
    return decode(FleetMirrorAction)(args)
  } catch {
    throw new HttpFailure(400, "Expected a mirror action")
  }
}

const decodeExecTask = (args: unknown): ExecTaskEventType => {
  try {
    return decode(ExecTaskEvent)(args)
  } catch {
    throw new HttpFailure(400, "Expected { sessionId, task, outputTail }")
  }
}
