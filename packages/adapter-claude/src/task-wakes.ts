import { randomUUID } from "node:crypto"

import type { SDKMessage } from "@anthropic-ai/claude-agent-sdk"

import type { BackgroundTaskEntry, ClaudeSession } from "./session.js"

export interface TaskWake {
  readonly taskId: string
  readonly status: string
  readonly summary: string
  readonly outputFile: string | undefined
}

type TaskNotificationMessage = Extract<SDKMessage, { type: "system"; subtype: "task_notification" }>

export const rememberNotifiedTask = (
  session: ClaudeSession,
  message: TaskNotificationMessage
): void => {
  if (message.skip_transcript === true) return

  rememberTaskWake(session, {
    taskId: message.task_id,
    status: message.status,
    summary: message.summary,
    outputFile: message.output_file
  })
}

export const rememberFinishedTask = (
  session: ClaudeSession,
  task: BackgroundTaskEntry,
  status: string
): void =>
  rememberTaskWake(session, {
    taskId: task.id,
    status,
    summary: task.description,
    outputFile: session.backgroundTaskOutputFiles.get(task.id)
  })

const rememberTaskWake = (session: ClaudeSession, wake: TaskWake): void => {
  if (session.turnActive) return

  const pending = session.pendingTaskWakes
  const index = pending.findIndex((known) => known.taskId === wake.taskId)
  if (index === -1) pending.push(wake)
  else pending[index] = wake
}

export const recordTaskWakes = (session: ClaudeSession): void => {
  const wakes = session.pendingTaskWakes.splice(0)
  if (wakes.length === 0) return

  void session.emit({
    kind: "session.output",
    payload: {
      role: "user",
      messageId: randomUUID(),
      origin: "event",
      startsTurn: true,
      text: wakes.map(wakeEvent).join("\n\n")
    },
    subjectId: session.key
  })
}

const wakeEvent = (wake: TaskWake): string =>
  [
    `<codevisor-event type="harness.task_finished" ${wakeAttributes(wake)}>`,
    wake.summary,
    "</codevisor-event>"
  ].join("\n")

const wakeAttributes = (wake: TaskWake): string =>
  [
    ["taskId", wake.taskId],
    ["status", wake.status],
    ["outputFile", wake.outputFile]
  ]
    .filter((pair): pair is [string, string] => pair[1] !== undefined)
    .map(([name, value]) => `${name}="${attribute(value)}"`)
    .join(" ")

const attribute = (value: string): string =>
  value.replaceAll("&", "&amp;").replaceAll('"', "&quot;").replaceAll("<", "&lt;")
