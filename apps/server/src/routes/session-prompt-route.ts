import type { ServerResponse } from "node:http"

import type {
  AttachmentRef,
  PromptAttribution,
  PromptOrigin,
  PromptQueueItem,
  PromptRequest as PromptRequestBody
} from "@codevisor/api"
import { PromptRequest } from "@codevisor/api"

import { HttpFailure, readSchema, run, sessionIsArchived, writeJson } from "../server-context.js"
import type { CodevisorServerServices, RouteState } from "../server-context.js"
import { agentMessageEvent } from "./bot-conversation.js"
import { conversationalBotForSession, postBotMessage } from "./bot-turns.js"
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
  refuseArchivedSession(await sessionIsArchived(services, summary))

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
  markPromptActionPending(routeState, actionKey)

  const toBot = (await conversationalBotForSession(services, sessionId)) !== undefined
  const agentSessionId = relayedAgentSessionId(toBot, payload, sessionId)
  const enqueue = promptEnqueuer(services, sessionId, payload, attachments, attribution)
  let queueItem: PromptQueueItem
  if (agentSessionId === undefined) {
    queueItem = await enqueue(payload.text, "user")
    if (toBot) await mirrorToBot(route, sessionId, queueItem, payload, attachments)
  } else {
    queueItem = await enqueue(await relayedMessage(services, agentSessionId, payload), "system")
  }

  const outcome = await deliverPrompt(route, sessionId, queueItem, payload)
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

const refuseArchivedSession = (archived: boolean): void => {
  if (archived) throw new HttpFailure(409, "Restore the workspace before sending a prompt")
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

const relayedAgentSessionId = (
  toBot: boolean,
  payload: PromptRequestBody,
  sessionId: string
): string | undefined =>
  isRelayFromAnotherSession(toBot, payload, sessionId) ? payload.fromSessionId : undefined

const isRelayFromAnotherSession = (
  toBot: boolean,
  payload: PromptRequestBody,
  sessionId: string
): boolean => toBot && payload.fromSessionId?.toLowerCase() !== sessionId.toLowerCase()

const promptEnqueuer = (
  services: CodevisorServerServices,
  sessionId: string,
  payload: PromptRequestBody,
  attachments: ReadonlyArray<AttachmentRef>,
  attribution: PromptAttribution | undefined
): EnqueuePrompt => {
  const createQueueItem = services.db.createPromptQueueItem
  const { messageId, clientId } = payload
  return (text, origin) =>
    run(createQueueItem(sessionId, text, attachments, messageId, clientId, origin, attribution))
}

const relayedMessage = (
  services: CodevisorServerServices,
  agentSessionId: string,
  payload: PromptRequestBody
): Promise<string> => agentMessageEvent(services, agentSessionId, payload.text)

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
  payload: PromptRequestBody
): Promise<PromptDeliveryOutcome> =>
  deliverQueuedPrompt(
    services,
    fanout,
    routeState,
    config.id,
    sessionId,
    queueItem.id,
    payload.delivery ?? defaultPromptDelivery,
    payload.fromSessionId !== undefined
  )
