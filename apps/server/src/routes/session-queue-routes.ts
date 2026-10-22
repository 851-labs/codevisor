import type { ServerResponse } from "node:http"

import type { AttachmentRef, PromptAcceptedResponse } from "@codevisor/api"
import { ReorderQueuedPromptsRequest, UpdateQueuedPromptRequest } from "@codevisor/api"

import {
  HttpFailure,
  matchRoute,
  matchRouteParams,
  readSchema,
  run,
  swallowError,
  writeJson
} from "../server-context.js"
import type { CodevisorServerServices } from "../server-context.js"
import { refuseWhileUpdating, sendQueuedPromptNow } from "./prompt-delivery.js"
import type { PromptDeliveryOutcome } from "./prompt-delivery.js"
import { drainPromptQueue, publishPromptQueue } from "./prompt-queue.js"
import type { RouteContext } from "./route-context.js"
import { routeParam } from "./route-params.js"
import { MAX_PROMPT_ATTACHMENTS } from "./sessions.js"

export const routeSessionQueue = (route: RouteContext): Promise<boolean> | undefined => {
  const { request, url } = route
  const queueSessionId = matchRoute(url.pathname, "/v1/sessions/:id/queue")
  if (queueSessionId !== undefined && request.method === "GET")
    return listQueue(route, queueSessionId)
  if (queueSessionId !== undefined && request.method === "PATCH")
    return reorderQueue(route, queueSessionId)
  return undefined
}

export const routeQueuedPrompt = (route: RouteContext): Promise<boolean> | undefined => {
  const { request, url } = route
  const queueItemRoute = matchRouteParams(url.pathname, "/v1/sessions/:id/queue/:queueId")
  if (queueItemRoute !== undefined && request.method === "PATCH")
    return updateQueuedPrompt(route, queueItemRoute)
  if (queueItemRoute !== undefined && request.method === "DELETE")
    return deleteQueuedPrompt(route, queueItemRoute)

  const sendNowRoute = matchRouteParams(url.pathname, "/v1/sessions/:id/queue/:queueId/send-now")
  if (sendNowRoute !== undefined && request.method === "POST") return sendNow(route, sendNowRoute)
  return undefined
}

export const requireKnownAttachments = async (
  services: CodevisorServerServices,
  attachments: ReadonlyArray<AttachmentRef>
): Promise<void> => {
  if (attachments.length > MAX_PROMPT_ATTACHMENTS) {
    throw new HttpFailure(422, `A prompt may carry at most ${MAX_PROMPT_ATTACHMENTS} attachments`)
  }
  for (const attachment of attachments) {
    if ((await run(services.db.getFileMetadata(attachment.fileId))) === undefined) {
      throw new HttpFailure(422, `Unknown attachment file: ${attachment.fileId}`)
    }
  }
}

export const acceptedPrompt = (
  sessionId: string,
  queueItemId: string,
  outcome: PromptDeliveryOutcome
): PromptAcceptedResponse => ({ accepted: true, sessionId, queueItemId, ...outcome })

export const drainQueueQuietly = (route: RouteContext, sessionId: string): Promise<void> =>
  drainPromptQueue(
    route.services,
    route.fanout,
    route.routeState,
    route.config.id,
    sessionId
  ).catch(swallowError)

const listQueue = async (
  { services, response }: RouteContext,
  sessionId: string
): Promise<boolean> => {
  writeJson(response, 200, await run(services.db.listPromptQueue(sessionId)))
  return true
}

const reorderQueue = async (
  { services, fanout, request, response }: RouteContext,
  sessionId: string
): Promise<boolean> => {
  const payload = await readSchema(request, ReorderQueuedPromptsRequest)
  await run(services.db.reorderPromptQueue(sessionId, payload.queueItemIds))
  writeJson(response, 200, await publishPromptQueue(services.db, fanout, sessionId))
  return true
}

const updateQueuedPrompt = async (
  { services, fanout, request, response }: RouteContext,
  params: Record<string, string>
): Promise<boolean> => {
  const id = routeParam(params, "id")
  const queueId = routeParam(params, "queueId")
  const payload = await readSchema(request, UpdateQueuedPromptRequest)
  if (payload.attachments !== undefined)
    await requireKnownAttachments(services, payload.attachments)

  const item = await run(
    services.db.updatePromptQueueItem(id, queueId, payload.text, payload.attachments)
  )
  await publishPromptQueue(services.db, fanout, id)
  writeJson(response, 200, item)
  return true
}

const deleteQueuedPrompt = async (
  { services, fanout, response }: RouteContext,
  params: Record<string, string>
): Promise<boolean> => {
  const id = routeParam(params, "id")
  const queueId = routeParam(params, "queueId")
  await run(services.db.deletePromptQueueItem(id, queueId))
  await publishPromptQueue(services.db, fanout, id)
  writeNoContent(response)
  return true
}

const sendNow = async (route: RouteContext, params: Record<string, string>): Promise<boolean> => {
  const { services, fanout, routeState, response, config } = route
  const id = routeParam(params, "id")
  const queueId = routeParam(params, "queueId")
  refuseWhileUpdating(routeState, id)

  const outcome = await sendQueuedPromptNow(services, fanout, routeState, config.id, id, queueId)
  writeJson(response, 200, acceptedPrompt(id, queueId, outcome))
  void drainQueueQuietly(route, id)
  return true
}

const writeNoContent = (response: ServerResponse): void => {
  writeJson(response, 204, {})
}
