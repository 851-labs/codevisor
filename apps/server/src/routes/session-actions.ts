import type { IncomingMessage, ServerResponse } from "node:http"

import type { AttachmentRef, PromptAcceptedResponse } from "@codevisor/api"
import {
  CancelRequest,
  PromptRequest,
  ReorderQueuedPromptsRequest,
  SetConfigRequest,
  SetGoalRequest,
  SetModeRequest,
  SetQuestionAnswerRequest,
  UpdateQueuedPromptRequest,
  isoTimestamp
} from "@codevisor/api"

import {
  HttpFailure,
  matchRoute,
  matchRouteParams,
  readSchema,
  run,
  sessionIsArchived,
  swallowError,
  writeJson
} from "../server-context.js"
import type {
  CodevisorServerConfig,
  CodevisorServerServices,
  EventFanout,
  RouteState
} from "../server-context.js"
import { agentMessageEvent, routeBotConversation } from "./bot-conversation.js"
import { conversationalBotForSession, postBotMessage } from "./bot-turns.js"
import {
  defaultPromptDelivery,
  deliverQueuedPrompt,
  refuseWhileUpdating,
  sendQueuedPromptNow
} from "./prompt-delivery.js"
import { drainPromptQueue, publishPromptQueue } from "./prompt-queue.js"
import { routeParam } from "./route-params.js"
import { applySessionConfigPick } from "./session-config.js"
import { openSessionAction } from "./session-open-action.js"
import { routeSessionTranscript } from "./session-transcript.js"
import { ensureAgentSessionFor } from "./session-workspace.js"
import { MAX_PROMPT_ATTACHMENTS } from "./sessions.js"

export const routeSessionActions = async (
  services: CodevisorServerServices,
  fanout: EventFanout,
  routeState: RouteState,
  request: IncomingMessage,
  response: ServerResponse,
  url: URL,
  config: CodevisorServerConfig
): Promise<boolean> => {
  const connectSessionId = matchRoute(url.pathname, "/v1/sessions/:id/connect")
  if (connectSessionId !== undefined && request.method === "POST") {
    const metadata = await ensureAgentSessionFor(services, fanout, config.id, connectSessionId)
    writeJson(response, 200, metadata)
    return true
  }

  const openSessionId = matchRoute(url.pathname, "/v1/sessions/:id/open")
  if (openSessionId !== undefined && request.method === "POST") {
    return openSessionAction(services, fanout, routeState, request, response, config, openSessionId)
  }

  if (
    request.method === "GET" &&
    (await routeSessionTranscript(services, routeState, request, response, url))
  ) {
    return true
  }

  if (await routeBotConversation(services, fanout, routeState, request, response, url)) {
    return true
  }

  const queueSessionId = matchRoute(url.pathname, "/v1/sessions/:id/queue")
  if (queueSessionId !== undefined && request.method === "GET") {
    writeJson(response, 200, await run(services.db.listPromptQueue(queueSessionId)))
    return true
  }

  if (queueSessionId !== undefined && request.method === "PATCH") {
    const payload = await readSchema(request, ReorderQueuedPromptsRequest)
    await run(services.db.reorderPromptQueue(queueSessionId, payload.queueItemIds))
    writeJson(response, 200, await publishPromptQueue(services.db, fanout, queueSessionId))
    return true
  }

  const eventsSessionId = matchRoute(url.pathname, "/v1/sessions/:id/events")
  if (eventsSessionId !== undefined && request.method === "GET") {
    throw new HttpFailure(410, "Use the paginated transcript endpoint and its event cursor")
  }

  const queueItemRoute = matchRouteParams(url.pathname, "/v1/sessions/:id/queue/:queueId")
  if (queueItemRoute !== undefined && request.method === "PATCH") {
    const id = routeParam(queueItemRoute, "id")
    const queueId = routeParam(queueItemRoute, "queueId")
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

  if (queueItemRoute !== undefined && request.method === "DELETE") {
    const id = routeParam(queueItemRoute, "id")
    const queueId = routeParam(queueItemRoute, "queueId")
    await run(services.db.deletePromptQueueItem(id, queueId))
    await publishPromptQueue(services.db, fanout, id)
    writeNoContent(response)
    return true
  }

  const sendNowRoute = matchRouteParams(url.pathname, "/v1/sessions/:id/queue/:queueId/send-now")
  if (sendNowRoute !== undefined && request.method === "POST") {
    const id = routeParam(sendNowRoute, "id")
    const queueId = routeParam(sendNowRoute, "queueId")
    refuseWhileUpdating(routeState, id)
    const outcome = await sendQueuedPromptNow(services, fanout, routeState, config.id, id, queueId)
    const result: PromptAcceptedResponse = {
      accepted: true,
      sessionId: id,
      queueItemId: queueId,
      ...outcome
    }
    writeJson(response, 200, result)
    void drainPromptQueue(services, fanout, routeState, config.id, id).catch(swallowError)
    return true
  }

  const promptSessionId = matchRoute(url.pathname, "/v1/sessions/:id/prompt")
  if (promptSessionId !== undefined && request.method === "POST") {
    if (
      await sessionIsArchived(services, await run(services.db.getSessionSummary(promptSessionId)))
    ) {
      throw new HttpFailure(409, "Restore the workspace before sending a prompt")
    }
    const payload = await readSchema(request, PromptRequest)
    const actionKey = actionIdKey(promptSessionId, payload.clientActionId)
    if (payload.clientActionId !== undefined) {
      const existing = await run(
        services.db.getSessionActionResult(promptSessionId, payload.clientActionId)
      )
      if (existing !== undefined) {
        writeJson(response, 202, existing)
        return true
      }
    }
    refuseWhileUpdating(routeState, promptSessionId)
    /* v8 ignore next 4 */
    if (actionKey !== undefined && routeState.pendingPromptActions.has(actionKey)) {
      writeJson(response, 202, { accepted: true, sessionId: promptSessionId })
      return true
    }
    const attachments = payload.attachments ?? []
    await requireKnownAttachments(services, attachments)
    if (actionKey !== undefined) {
      routeState.pendingPromptActions.add(actionKey)
    }
    const toBot = (await conversationalBotForSession(services, promptSessionId)) !== undefined
    const agentSessionId =
      toBot && payload.fromSessionId?.toLowerCase() !== promptSessionId.toLowerCase()
        ? payload.fromSessionId
        : undefined
    const queueItem = await run(
      services.db.createPromptQueueItem(
        promptSessionId,
        agentSessionId === undefined
          ? payload.text
          : await agentMessageEvent(services, agentSessionId, payload.text),
        attachments,
        payload.messageId,
        payload.clientId,
        agentSessionId === undefined ? "user" : "system"
      )
    )
    if (toBot && agentSessionId === undefined) {
      await postBotMessage(services, fanout, promptSessionId, {
        id: queueItem.id,
        sender: "user",
        text: payload.text,
        ...(attachments.length === 0 ? {} : { attachments })
      })
    }
    const outcome = await deliverQueuedPrompt(
      services,
      fanout,
      routeState,
      config.id,
      promptSessionId,
      queueItem.id,
      payload.delivery ?? defaultPromptDelivery
    )
    const result: PromptAcceptedResponse = {
      accepted: true,
      sessionId: promptSessionId,
      queueItemId: queueItem.id,
      ...outcome
    }
    if (payload.clientActionId !== undefined) {
      await run(
        services.db.saveSessionActionResult(
          promptSessionId,
          payload.clientActionId,
          "prompt",
          result
        )
      )
    }
    writeJson(response, 202, result)
    void drainPromptQueue(services, fanout, routeState, config.id, promptSessionId)
      .catch(swallowError)
      .finally(() => {
        if (actionKey !== undefined) {
          routeState.pendingPromptActions.delete(actionKey)
        }
      })
    return true
  }

  const cancelSessionId = matchRoute(url.pathname, "/v1/sessions/:id/cancel")
  if (cancelSessionId !== undefined && request.method === "POST") {
    const payload = await readSchema(request, CancelRequest)
    await writeIdempotentAction(
      services,
      response,
      cancelSessionId,
      "cancel",
      payload,
      async () => {
        routeState.updateResume.cancel(cancelSessionId)
        const cancelRequestedAt = isoTimestamp()
        const session = await run(services.db.getSessionSummary(cancelSessionId))
        const activeItem = (
          await run(services.db.getTranscriptPage(cancelSessionId, undefined, 1))
        ).items.at(-1)
        const agentSession = await ensureAgentSessionFor(
          services,
          fanout,
          config.id,
          cancelSessionId
        )
        const outcome = await run(services.agents.cancel(agentSession.sessionId))
        if (outcome.runtimeState === "retire") {
          const forcedAt = isoTimestamp()
          console.error(
            JSON.stringify({
              event: "agent_cancel_forced",
              sessionId: cancelSessionId,
              harnessId: session.harnessId,
              agentSessionId: agentSession.sessionId,
              turnId: activeItem?.turnId,
              providerPhase: "cancelling",
              lastEventType: "durable_transcript_snapshot",
              lastEventAt: activeItem?.updatedAt,
              cancelRequestedAt,
              forcedAt,
              runtimeRetired: true,
              bootId: config.bootId,
              processId: config.processId,
              version: config.version,
              buildNumber: config.buildNumber,
              sourceRevision: config.sourceRevision
            })
          )
        }
        return { cancelled: true }
      }
    )
    return true
  }

  const modeSessionId = matchRoute(url.pathname, "/v1/sessions/:id/mode")
  if (modeSessionId !== undefined && request.method === "POST") {
    const payload = await readSchema(request, SetModeRequest)
    await writeIdempotentAction(services, response, modeSessionId, "mode", payload, async () => {
      const agentSession = await ensureAgentSessionFor(services, fanout, config.id, modeSessionId)
      await run(services.agents.setMode(agentSession.sessionId, payload.modeId))
      return { modeId: payload.modeId }
    })
    return true
  }

  const configSessionId = matchRoute(url.pathname, "/v1/sessions/:id/config")
  if (configSessionId !== undefined && request.method === "POST") {
    const payload = await readSchema(request, SetConfigRequest)
    await writeIdempotentAction(
      services,
      response,
      configSessionId,
      "config",
      payload,
      async () => {
        return applySessionConfigPick(services, fanout, config.id, configSessionId, payload)
      }
    )
    return true
  }

  const goalSessionId = matchRoute(url.pathname, "/v1/sessions/:id/goal")
  if (goalSessionId !== undefined && request.method === "POST") {
    refuseWhileUpdating(routeState, goalSessionId)
    const payload = await readSchema(request, SetGoalRequest)
    await writeIdempotentAction(services, response, goalSessionId, "goal", payload, async () => {
      const agentSession = await ensureAgentSessionFor(services, fanout, config.id, goalSessionId)
      return await run(
        services.agents.setGoal(agentSession.sessionId, {
          ...(payload.objective === undefined ? {} : { objective: payload.objective }),
          ...(payload.status === undefined ? {} : { status: payload.status }),
          ...("tokenBudget" in payload ? { tokenBudget: payload.tokenBudget ?? null } : {})
        })
      )
    })
    return true
  }
  if (goalSessionId !== undefined && request.method === "DELETE") {
    const agentSession = await ensureAgentSessionFor(services, fanout, config.id, goalSessionId)
    await run(services.agents.clearGoal(agentSession.sessionId))
    writeJson(response, 204, undefined)
    return true
  }

  const answerRoute = matchRouteParams(
    url.pathname,
    "/v1/sessions/:id/questions/:questionId/answer"
  )
  if (answerRoute !== undefined && request.method === "POST") {
    const answerSessionId = routeParam(answerRoute, "id")
    const questionId = routeParam(answerRoute, "questionId")
    const payload = await readSchema(request, SetQuestionAnswerRequest)
    await writeIdempotentAction(
      services,
      response,
      answerSessionId,
      "question-answer",
      payload,
      async () => {
        const answer = {
          outcome: payload.outcome,
          ...(payload.answers === undefined ? {} : { answers: payload.answers })
        }
        const handledByAutomation =
          (await services.mcp?.answerQuestion(answerSessionId, questionId, answer)) ?? false
        if (!handledByAutomation) {
          const agentSession = await ensureAgentSessionFor(
            services,
            fanout,
            config.id,
            answerSessionId
          )
          await run(services.agents.answerQuestion(agentSession.sessionId, questionId, answer))
        }
        return { outcome: payload.outcome, questionId }
      }
    )
    return true
  }

  return false
}

const writeIdempotentAction = async (
  services: CodevisorServerServices,
  response: ServerResponse,
  sessionId: string,
  actionKind: string,
  payload: { readonly clientActionId?: string | undefined },
  runAction: () => Promise<unknown>
): Promise<void> => {
  if (payload.clientActionId !== undefined) {
    const existing = await run(
      services.db.getSessionActionResult(sessionId, payload.clientActionId)
    )
    if (existing !== undefined) {
      writeJson(response, 202, existing)
      return
    }
  }
  const result = await runAction()
  if (payload.clientActionId !== undefined) {
    await run(
      services.db.saveSessionActionResult(sessionId, payload.clientActionId, actionKind, result)
    )
  }
  writeJson(response, 202, result)
}

const actionIdKey = (sessionId: string, clientActionId: string | undefined): string | undefined =>
  clientActionId === undefined ? undefined : `${sessionId}:${clientActionId}`

const writeNoContent = (response: ServerResponse): void => {
  writeJson(response, 204, {})
}

const requireKnownAttachments = async (
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
