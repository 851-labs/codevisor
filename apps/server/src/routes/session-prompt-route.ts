import type { ServerResponse } from "node:http"

import type {
  AgentRef,
  AttachmentRef,
  Bot,
  PromptOrigin,
  PromptQueueItem,
  PromptRequest as PromptRequestBody,
  PromptSource
} from "@codevisor/api"
import { PromptRequest } from "@codevisor/api"

import { archivedChatRefusal, HttpFailure, readSchema, run, writeJson } from "../server-context.js"
import type { CodevisorServerServices, RouteState } from "../server-context.js"
import { botForChat, postBotMessage } from "./bot-turns.js"
import { assertAgentVerified, remoteCallerAgent } from "./fleet-calls.js"
import { verifiedAttribution } from "./prompt-attribution.js"
import type { PromptDeliveryOutcome } from "./prompt-delivery.js"
import {
  defaultPromptDelivery,
  deliverQueuedPrompt,
  refuseWhileUpdating
} from "./prompt-delivery.js"
import type { RouteContext } from "./route-context.js"
import { saveActionResult, savedActionResult } from "./session-action-results.js"
import {
  acceptedPrompt,
  drainQueueQuietly,
  requireKnownAttachments
} from "./session-queue-routes.js"

type EnqueuePrompt = (text: string, origin: PromptOrigin) => Promise<PromptQueueItem>

export const sendPrompt = async (route: RouteContext, sessionId: string): Promise<boolean> => {
  const { services, routeState, request, response } = route
  const summary = await run(services.db.getSessionSummary(sessionId))
  refuseArchivedSession(await archivedChatRefusal(services, summary, "sending a prompt"))

  const payload = await readSchema(request, PromptRequest)
  const actionKey = actionIdKey(sessionId, payload.clientActionId)
  if (payload.clientActionId !== undefined) {
    const existing = await savedActionResult(services, sessionId, payload.clientActionId)
    if (existing !== undefined) return writeAccepted(response, existing)
  }

  await refuseWhileUpdating(services, routeState, sessionId)
  /* v8 ignore next 3 */
  if (promptActionPending(routeState, actionKey)) {
    return writeAccepted(response, { accepted: true, sessionId })
  }

  const attachments = payload.attachments ?? []
  await requireKnownAttachments(services, attachments)
  const attribution = await verifiedAttribution(services, sessionId, payload.attribution)
  const sentByAgent = verifiedSender(route, payload)
  const bot = await botForChat(services, sessionId)
  refuseAgentMessageToBot(bot, sentByAgent, sessionId)
  markPromptActionPending(routeState, actionKey)

  const enqueue = promptEnqueuer(services, sessionId, payload, attachments, {
    attribution,
    sentByAgent
  })
  const queueItem = await enqueue(payload.text, "user")
  if (bot !== undefined) await mirrorToBot(route, sessionId, queueItem, payload, attachments)

  const outcome = await deliverPrompt(route, sessionId, queueItem, payload, sentByAgent)
  const result = acceptedPrompt(sessionId, queueItem.id, outcome)
  if (payload.clientActionId !== undefined) {
    await saveActionResult(services, sessionId, payload.clientActionId, "prompt", result)
  }

  writeJson(response, 202, result)
  void drainQueueQuietly(route, sessionId).finally(() =>
    clearPromptActionPending(routeState, actionKey)
  )
  return true
}

const refuseArchivedSession = (refusal: string | undefined): void => {
  if (refusal !== undefined) throw new HttpFailure(409, refusal)
}

const writeAccepted = (response: ServerResponse, body: unknown): boolean => {
  writeJson(response, 202, body)
  return true
}

const actionIdKey = (sessionId: string, clientActionId: string | undefined): string | undefined =>
  clientActionId === undefined ? undefined : `${sessionId}:${clientActionId}`

const promptActionPending = (routeState: RouteState, actionKey: string | undefined): boolean =>
  actionKey !== undefined && routeState.pendingPromptActions.has(actionKey)

const markPromptActionPending = (routeState: RouteState, actionKey: string | undefined): void => {
  if (actionKey !== undefined) {
    routeState.pendingPromptActions.add(actionKey)
  }
}

const clearPromptActionPending = (routeState: RouteState, actionKey: string | undefined): void => {
  if (actionKey !== undefined) {
    routeState.pendingPromptActions.delete(actionKey)
  }
}

const verifiedSender = (route: RouteContext, payload: PromptRequestBody): AgentRef | undefined => {
  if (payload.sentByAgentId === undefined) return undefined
  const machineId = payload.sentByAgentMachineId ?? route.config.id
  const claimed = { agentId: payload.sentByAgentId, machineId }
  assertAgentVerified(route.config.id, claimed, remoteCallerAgent(route.services, route.request))
  return claimed
}

const refuseAgentMessageToBot = (
  bot: Bot | undefined,
  sender: AgentRef | undefined,
  sessionId: string
): void => {
  if (bot === undefined || sender === undefined || isSelf(sender, sessionId)) return
  throw new HttpFailure(
    409,
    `${bot.name} is a bot, not an agent. Message it with bots.message({ botId: "${bot.id}", text })`
  )
}

const isSelf = (sender: AgentRef | undefined, sessionId: string): boolean =>
  sender?.agentId.toLowerCase() === sessionId.toLowerCase()

const promptEnqueuer = (
  services: CodevisorServerServices,
  sessionId: string,
  payload: PromptRequestBody,
  attachments: ReadonlyArray<AttachmentRef>,
  source: PromptSource
): EnqueuePrompt => {
  const createQueueItem = services.db.createPromptQueueItem
  const { messageId, clientId } = payload
  return (text, origin) =>
    run(createQueueItem(sessionId, text, attachments, messageId, clientId, origin, source))
}

const mirrorToBot = (
  { services, fanout }: RouteContext,
  sessionId: string,
  queueItem: PromptQueueItem,
  payload: PromptRequestBody,
  attachments: ReadonlyArray<AttachmentRef>
): Promise<unknown> =>
  postBotMessage(services, fanout, sessionId, {
    id: queueItem.id,
    sender: "user",
    text: payload.text,
    ...(attachments.length === 0 ? {} : { attachments })
  })

const deliverPrompt = (
  { services, fanout, routeState, config }: RouteContext,
  sessionId: string,
  queueItem: PromptQueueItem,
  payload: PromptRequestBody,
  sentByAgent: AgentRef | undefined
): Promise<PromptDeliveryOutcome> =>
  deliverQueuedPrompt(
    services,
    fanout,
    routeState,
    config.id,
    sessionId,
    queueItem.id,
    payload.delivery ?? defaultPromptDelivery,
    sentByAgent !== undefined
  )
