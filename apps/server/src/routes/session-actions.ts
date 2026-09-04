import type { PromptAcceptedResponse } from "@codevisor/api"
import {
  OpenSessionRequest as OpenSessionRequestSchema,
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
import type { IncomingMessage, ServerResponse } from "node:http"
import {
  appendAndPublish,
  HttpFailure,
  matchRoute,
  matchRouteParams,
  readSchema,
  run,
  swallowError,
  writeJson
} from "../server-context.js"
import type {
  CodevisorServerConfig,
  CodevisorServerServices,
  EventFanout,
  RouteState
} from "../server-context.js"
import { drainPromptQueue, publishPromptQueue } from "./prompt-queue.js"
import {
  applySessionUpdate,
  configSelectionsFromOptions,
  createSessionIfMissing,
  ensureAgentSessionFor,
  findSession,
  sessionHistoryEventsWithSetup
} from "./session-workspace.js"
import { MAX_PROMPT_ATTACHMENTS } from "./sessions.js"
import { withUpdateGate } from "./update-gate.js"

/// Per-session action routes: connect, prompt, cancel, mode/config, goals,
/// questions, queue management, and read/attention state.

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

  // One-round-trip chat open: ensure the project and session records exist
  // and return the first transcript page together, replacing the client's
  // listProjects → createProject → listSessions → create/update → transcript
  // waterfall. Deliberately does NOT touch the agent runtime — clients call
  // /connect in parallel so the transcript can paint while the agent process
  // is still spawning. Older clients keep using the discrete routes; newer
  // clients fall back to them when this route 404s on an older server.
  const openSessionId = matchRoute(url.pathname, "/v1/sessions/:id/open")
  if (openSessionId !== undefined && request.method === "POST") {
    const payload = await readSchema(request, OpenSessionRequestSchema)
    if (
      payload.session.id !== undefined &&
      payload.session.id.toLowerCase() !== openSessionId.toLowerCase()
    ) {
      throw new HttpFailure(400, "Session id in body does not match the path")
    }
    const limit = payload.transcriptLimit ?? 32
    if (!Number.isSafeInteger(limit) || limit < 1) {
      throw new HttpFailure(400, "Invalid transcript page limit")
    }
    // Project: create-if-missing. An existing record is never updated from
    // the open snapshot — it may predate changes made elsewhere (archiving),
    // and opening a chat must not revert them.
    if (payload.project?.id !== undefined) {
      const wanted = payload.project.id.toLowerCase()
      const exists = (await run(services.db.listProjects)).some(
        (candidate) => candidate.id.toLowerCase() === wanted
      )
      if (!exists) {
        const project = await run(services.db.createProject(payload.project))
        await appendAndPublish(services.db, fanout, "project.created", project.id, project)
      }
    }
    const existing = await findSession(services.db, openSessionId)
    const session =
      existing === undefined
        ? (
            await createSessionIfMissing(services, fanout, routeState, config, {
              ...payload.session,
              id: openSessionId
            })
          ).session
        : payload.update === undefined
          ? existing
          : await applySessionUpdate(services, fanout, config, openSessionId, payload.update)
    const transcript = withUpdateGate(
      await run(services.db.getTranscriptPage(openSessionId, undefined, limit)),
      services,
      routeState,
      openSessionId
    )
    writeJson(response, 200, { session, transcript })
    return true
  }

  const transcriptSessionId = matchRoute(url.pathname, "/v1/sessions/:id/transcript")
  if (transcriptSessionId !== undefined && request.method === "GET") {
    const rawBefore = url.searchParams.get("before")
    const before = rawBefore === null ? undefined : Number(rawBefore)
    if (before !== undefined && (!Number.isSafeInteger(before) || before < 0)) {
      throw new HttpFailure(400, "Invalid transcript cursor")
    }
    const rawLimit = url.searchParams.get("limit")
    const limit = rawLimit === null ? 32 : Number(rawLimit)
    if (!Number.isSafeInteger(limit) || limit < 1) {
      throw new HttpFailure(400, "Invalid transcript page limit")
    }
    writeJson(
      response,
      200,
      withUpdateGate(
        await run(services.db.getTranscriptPage(transcriptSessionId, before, limit)),
        services,
        routeState,
        transcriptSessionId
      )
    )
    return true
  }

  const transcriptDetails = matchRouteParams(
    url.pathname,
    "/v1/sessions/:id/transcript/:itemId/details"
  )
  if (transcriptDetails !== undefined && request.method === "GET") {
    const { id, itemId } = transcriptDetails as { readonly id: string; readonly itemId: string }
    const rawThrough = url.searchParams.get("through")
    const through = rawThrough === null ? undefined : Number(rawThrough)
    if (through !== undefined && (!Number.isSafeInteger(through) || through < 0)) {
      throw new HttpFailure(400, "Invalid transcript detail cursor")
    }
    const details = await run(services.db.getTranscriptItemDetails(id, itemId, through))
    if (details === undefined) {
      throw new HttpFailure(404, `Transcript item not found: ${itemId}`)
    }
    writeJson(response, 200, details)
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

  // Full persisted event history for one session — the client replays these
  // through its live pipeline to rebuild rich transcripts (tool calls, diffs)
  // that the text-only conversation snapshot cannot carry.
  const eventsSessionId = matchRoute(url.pathname, "/v1/sessions/:id/events")
  if (eventsSessionId !== undefined && request.method === "GET") {
    writeJson(
      response,
      200,
      await sessionHistoryEventsWithSetup(services.db, config.id, eventsSessionId)
    )
    return true
  }

  const queueItemRoute = matchRouteParams(url.pathname, "/v1/sessions/:id/queue/:queueId")
  if (queueItemRoute !== undefined && request.method === "PATCH") {
    const { id, queueId } = queueItemRoute as { readonly id: string; readonly queueId: string }
    const payload = await readSchema(request, UpdateQueuedPromptRequest)
    const item = await run(services.db.updatePromptQueueItem(id, queueId, payload.text))
    await publishPromptQueue(services.db, fanout, id)
    writeJson(response, 200, item)
    return true
  }

  if (queueItemRoute !== undefined && request.method === "DELETE") {
    const { id, queueId } = queueItemRoute as { readonly id: string; readonly queueId: string }
    await run(services.db.deletePromptQueueItem(id, queueId))
    await publishPromptQueue(services.db, fanout, id)
    writeNoContent(response)
    return true
  }

  const promptSessionId = matchRoute(url.pathname, "/v1/sessions/:id/prompt")
  if (promptSessionId !== undefined && request.method === "POST") {
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
    /* v8 ignore next 4 -- duplicate in-flight requests normally hit the saved idempotency row above. */
    if (actionKey !== undefined && routeState.pendingPromptActions.has(actionKey)) {
      writeJson(response, 202, { accepted: true, sessionId: promptSessionId })
      return true
    }
    const attachments = payload.attachments ?? []
    if (attachments.length > MAX_PROMPT_ATTACHMENTS) {
      throw new HttpFailure(422, `A prompt may carry at most ${MAX_PROMPT_ATTACHMENTS} attachments`)
    }
    // Fail unknown file ids at send time rather than mid-drain.
    for (const attachment of attachments) {
      if ((await run(services.db.getFileMetadata(attachment.fileId))) === undefined) {
        throw new HttpFailure(422, `Unknown attachment file: ${attachment.fileId}`)
      }
    }
    if (actionKey !== undefined) {
      routeState.pendingPromptActions.add(actionKey)
    }
    const queueItem = await run(
      services.db.createPromptQueueItem(
        promptSessionId,
        payload.text,
        attachments,
        payload.messageId
      )
    )
    const result: PromptAcceptedResponse = {
      accepted: true,
      sessionId: promptSessionId,
      queueItemId: queueItem.id
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
        const agentSession = await ensureAgentSessionFor(
          services,
          fanout,
          config.id,
          configSessionId
        )
        const configOptions = await run(
          services.agents.setConfigOption(agentSession.sessionId, payload.configId, payload.value)
        )
        await run(
          services.db.replaceSessionConfigSelections(
            configSessionId,
            configSelectionsFromOptions(configOptions)
          )
        )
        return { configId: payload.configId, configOptions }
      }
    )
    return true
  }

  const goalSessionId = matchRoute(url.pathname, "/v1/sessions/:id/goal")
  if (goalSessionId !== undefined && request.method === "POST") {
    const payload = await readSchema(request, SetGoalRequest)
    await writeIdempotentAction(services, response, goalSessionId, "goal", payload, async () => {
      const agentSession = await ensureAgentSessionFor(services, fanout, config.id, goalSessionId)
      // Double-option passthrough: only forward the tokenBudget key when the
      // client sent one (absent = keep, null = clear, number = set).
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
    const answerSessionId = answerRoute.id as string
    const questionId = answerRoute.questionId as string
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
