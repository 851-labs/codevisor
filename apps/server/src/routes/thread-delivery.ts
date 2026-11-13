import { randomUUID } from "node:crypto"

import {
  FLEET_SESSION_EVENT_PATH,
  FLEET_THREAD_MESSAGE_PATH,
  type FleetThreadMessage,
  type Thread,
  type ThreadMessage,
  type ThreadParticipant
} from "@codevisor/api"

import { fleetLinkFor } from "../infra/fleet-outbox.js"
import { run, swallowError } from "../server-context.js"
import { drainPromptQueue } from "./prompt-queue.js"
import type { RouteContext } from "./route-context.js"
import { attribute } from "./session-event-messages.js"
import { recordUserPrompt } from "./user-prompts.js"

export const isOnAnotherMachine = (
  { config }: RouteContext,
  participant: ThreadParticipant
): boolean => participant.machineId !== undefined && participant.machineId !== config.id

export const sameParticipant = (first: ThreadParticipant, second: ThreadParticipant): boolean =>
  first.agentId === second.agentId && first.machineId === second.machineId

export const announceThreadMessage = async (
  route: RouteContext,
  thread: Thread,
  message: ThreadMessage
): Promise<void> => {
  for (const participant of thread.participants) {
    const wroteIt = sameParticipant(participant, message.from)
    if (isOnAnotherMachine(route, participant)) {
      await sendToMachine(route, participant, thread, message, wroteIt)
    } else if (wroteIt) {
      await noteSentInChat(route, thread, message)
    } else {
      await deliverToChat(route, participant.agentId, threadEvent(route, message))
    }
  }
}

export const deliverToChat = async (
  { services, fanout, routeState, config }: RouteContext,
  sessionId: string,
  text: string
): Promise<void> => {
  await run(services.db.createPromptQueueItem(sessionId, text, [], undefined, undefined, "system"))
  void drainPromptQueue(services, fanout, routeState, config.id, sessionId).catch(swallowError)
}

export const noteSentInChat = async (
  route: RouteContext,
  thread: Thread,
  message: ThreadMessage
): Promise<void> => {
  const { services, fanout, config } = route
  const to = thread.participants.find((participant) => !sameParticipant(participant, message.from))
  if (message.from.botId === undefined || to === undefined) return
  await recordUserPrompt(services, fanout, config.id, message.from.agentId, {
    messageId: randomUUID(),
    text: eventText(route, message, "to", to),
    attachments: undefined,
    origin: "system",
    startsTurn: false
  })
}

export const threadEvent = (route: RouteContext, message: ThreadMessage): string =>
  eventText(route, message, "from", message.from)

const eventText = (
  { config }: RouteContext,
  message: ThreadMessage,
  direction: "from" | "to",
  other: ThreadParticipant
): string => {
  const who =
    other.botId === undefined
      ? `${direction}="agent" agentId="${attribute(other.agentId)}"`
      : `${direction}="bot" botId="${attribute(other.botId)}"`
  const machine = ` machineId="${attribute(other.machineId ?? config.id)}"`
  return [
    `<codevisor-event type="thread.message" threadId="${attribute(message.threadId)}" ${who}${machine} name="${attribute(other.name)}">`,
    message.text,
    "</codevisor-event>"
  ].join("\n")
}

const sendToMachine = async (
  route: RouteContext,
  to: ThreadParticipant,
  thread: Thread,
  message: ThreadMessage,
  wroteIt: boolean
): Promise<void> => {
  if (to.botId !== undefined) {
    const args = { ...fleetThreadMessage(route, thread, message) }
    await enqueue(route, to, { path: FLEET_THREAD_MESSAGE_PATH, messageId: message.id, args })
  } else if (!wroteIt) {
    const args = {
      sessionId: to.agentId,
      deliveryId: `thread:${message.id}`,
      text: threadEvent(route, message)
    }
    await enqueue(route, to, { path: FLEET_SESSION_EVENT_PATH, messageId: message.id, args })
  }
}

const fleetThreadMessage = (
  { config }: RouteContext,
  thread: Thread,
  message: ThreadMessage
): FleetThreadMessage => {
  const placed = (participant: ThreadParticipant): ThreadParticipant => ({
    ...participant,
    machineId: participant.machineId ?? config.id
  })
  return {
    threadId: thread.threadId,
    participants: thread.participants.map(placed),
    message: { ...message, from: placed(message.from) }
  }
}

interface Outgoing {
  readonly path: string
  readonly messageId: string
  readonly args: Readonly<Record<string, unknown>>
}

const enqueue = async (
  { services, config }: RouteContext,
  to: ThreadParticipant,
  outgoing: Outgoing
): Promise<void> => {
  await run(
    services.db.enqueueFleetMessage({
      id: `${config.id}:${outgoing.path}:${to.agentId}:${outgoing.messageId}`,
      machineId: to.machineId!,
      path: outgoing.path,
      args: outgoing.args,
      origin: { machineId: config.id, machineName: config.name },
      createdAt: new Date().toISOString()
    })
  )
  void fleetLinkFor(services)?.outbox.flush().catch(swallowError)
}
