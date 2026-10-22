import type { AgentSessionMetadata, QuestionAnswer, SetGoalUpdate } from "@codevisor/agent-runtime"
import type {
  SessionGoal,
  SessionSummary,
  SetGoalRequest as SetGoalRequestBody,
  SetModeRequest as SetModeRequestBody,
  SetQuestionAnswerRequest as SetQuestionAnswerRequestBody,
  TranscriptItem,
  TranscriptPage
} from "@codevisor/api"
import {
  CancelRequest,
  SetConfigRequest,
  SetGoalRequest,
  SetModeRequest,
  SetQuestionAnswerRequest,
  isoTimestamp
} from "@codevisor/api"

import {
  HttpFailure,
  matchRoute,
  matchRouteParams,
  readSchema,
  run,
  writeJson
} from "../server-context.js"
import type { CodevisorServerConfig, CodevisorServerServices } from "../server-context.js"
import { routeBotConversation } from "./bot-conversation.js"
import { refuseWhileUpdating } from "./prompt-delivery.js"
import { rejectSyncThrows } from "./route-context.js"
import type { RouteContext } from "./route-context.js"
import { routeParam } from "./route-params.js"
import { writeIdempotentAction } from "./session-action-results.js"
import { applySessionConfigPick } from "./session-config.js"
import { openSessionAction } from "./session-open-action.js"
import { sendPrompt } from "./session-prompt-route.js"
import { routeQueuedPrompt, routeSessionQueue } from "./session-queue-routes.js"
import { routeSessionTranscript } from "./session-transcript.js"
import { ensureAgentSessionFor } from "./session-workspace.js"

export const routeSessionActions = (route: RouteContext): Promise<boolean> =>
  rejectSyncThrows(() => dispatchSessionAction(route))

const dispatchSessionAction = (route: RouteContext): Promise<boolean> => {
  const { request, url } = route
  const connectSessionId = matchRoute(url.pathname, "/v1/sessions/:id/connect")
  if (connectSessionId !== undefined && request.method === "POST")
    return connectSession(route, connectSessionId)

  const openSessionId = matchRoute(url.pathname, "/v1/sessions/:id/open")
  if (openSessionId !== undefined && request.method === "POST")
    return openSession(route, openSessionId)

  return routeAfterDelegates(route)
}

const routeAfterDelegates = async (route: RouteContext): Promise<boolean> => {
  const { services, fanout, routeState, request, response, url } = route
  if (
    request.method === "GET" &&
    (await routeSessionTranscript(services, routeState, request, response, url))
  ) {
    return true
  }
  if (await routeBotConversation(services, fanout, routeState, request, response, url)) {
    return true
  }

  const queueRoute = routeSessionQueue(route)
  if (queueRoute !== undefined) return queueRoute

  refuseRemovedEventsRoute(route)

  return routeQueuedPrompt(route) ?? routeSessionCommand(route) ?? false
}

const refuseRemovedEventsRoute = ({ request, url }: RouteContext): void => {
  const eventsSessionId = matchRoute(url.pathname, "/v1/sessions/:id/events")
  if (eventsSessionId !== undefined && request.method === "GET") {
    throw new HttpFailure(410, "Use the paginated transcript endpoint and its event cursor")
  }
}

const routeSessionCommand = (route: RouteContext): Promise<boolean> | undefined => {
  const { request, url } = route
  const promptSessionId = matchRoute(url.pathname, "/v1/sessions/:id/prompt")
  if (promptSessionId !== undefined && request.method === "POST")
    return sendPrompt(route, promptSessionId)

  const cancelSessionId = matchRoute(url.pathname, "/v1/sessions/:id/cancel")
  if (cancelSessionId !== undefined && request.method === "POST")
    return cancelSession(route, cancelSessionId)

  const modeSessionId = matchRoute(url.pathname, "/v1/sessions/:id/mode")
  if (modeSessionId !== undefined && request.method === "POST") return setMode(route, modeSessionId)

  const configSessionId = matchRoute(url.pathname, "/v1/sessions/:id/config")
  if (configSessionId !== undefined && request.method === "POST")
    return setConfig(route, configSessionId)

  const goalSessionId = matchRoute(url.pathname, "/v1/sessions/:id/goal")
  if (goalSessionId !== undefined && request.method === "POST") return setGoal(route, goalSessionId)
  if (goalSessionId !== undefined && request.method === "DELETE")
    return clearGoal(route, goalSessionId)

  const answerRoute = matchRouteParams(
    url.pathname,
    "/v1/sessions/:id/questions/:questionId/answer"
  )
  if (answerRoute !== undefined && request.method === "POST")
    return answerQuestion(route, answerRoute)
  return undefined
}

const connectSession = async (route: RouteContext, sessionId: string): Promise<boolean> => {
  const metadata = await agentSessionFor(route, sessionId)
  writeJson(route.response, 200, metadata)
  return true
}

const openSession = async (
  { services, fanout, routeState, request, response, config }: RouteContext,
  sessionId: string
): Promise<boolean> =>
  openSessionAction(services, fanout, routeState, request, response, config, sessionId)

const cancelSession = async (route: RouteContext, sessionId: string): Promise<boolean> => {
  const payload = await readSchema(route.request, CancelRequest)
  await writeIdempotentAction(route.services, route.response, sessionId, "cancel", payload, () =>
    cancelTurn(route, sessionId)
  )
  return true
}

const cancelTurn = async (route: RouteContext, sessionId: string): Promise<CancelResult> => {
  const { services, routeState, config } = route
  routeState.updateResume.cancel(sessionId)
  const cancelRequestedAt = isoTimestamp()
  const session = await run(services.db.getSessionSummary(sessionId))
  const activeItem = (await latestTranscriptPage(services, sessionId)).items.at(-1)
  const agentSession = await agentSessionFor(route, sessionId)
  const outcome = await run(services.agents.cancel(agentSession.sessionId))
  if (outcome.runtimeState === "retire") {
    logForcedCancel(config, { sessionId, session, agentSession, activeItem, cancelRequestedAt })
  }
  return { cancelled: true }
}

const setMode = async (route: RouteContext, sessionId: string): Promise<boolean> => {
  const payload = await readSchema(route.request, SetModeRequest)
  await writeIdempotentAction(route.services, route.response, sessionId, "mode", payload, () =>
    applyMode(route, sessionId, payload)
  )
  return true
}

const applyMode = async (
  route: RouteContext,
  sessionId: string,
  payload: SetModeRequestBody
): Promise<ModeResult> => {
  const agentSession = await agentSessionFor(route, sessionId)
  await run(route.services.agents.setMode(agentSession.sessionId, payload.modeId))
  return { modeId: payload.modeId }
}

const setConfig = async (route: RouteContext, sessionId: string): Promise<boolean> => {
  const { services, fanout, request, response, config } = route
  const payload = await readSchema(request, SetConfigRequest)
  await writeIdempotentAction(services, response, sessionId, "config", payload, async () =>
    applySessionConfigPick(services, fanout, config.id, sessionId, payload)
  )
  return true
}

const setGoal = async (route: RouteContext, sessionId: string): Promise<boolean> => {
  await refuseWhileUpdating(route.services, route.routeState, sessionId)
  const payload = await readSchema(route.request, SetGoalRequest)
  await writeIdempotentAction(route.services, route.response, sessionId, "goal", payload, () =>
    applyGoal(route, sessionId, payload)
  )
  return true
}

const applyGoal = async (
  route: RouteContext,
  sessionId: string,
  payload: SetGoalRequestBody
): Promise<SessionGoal> => {
  const agentSession = await agentSessionFor(route, sessionId)
  return await run(route.services.agents.setGoal(agentSession.sessionId, goalUpdate(payload)))
}

const clearGoal = async (route: RouteContext, sessionId: string): Promise<boolean> => {
  const agentSession = await agentSessionFor(route, sessionId)
  await run(route.services.agents.clearGoal(agentSession.sessionId))
  writeJson(route.response, 204, undefined)
  return true
}

const answerQuestion = async (
  route: RouteContext,
  params: Record<string, string>
): Promise<boolean> => {
  const sessionId = routeParam(params, "id")
  const questionId = routeParam(params, "questionId")
  const payload = await readSchema(route.request, SetQuestionAnswerRequest)
  await writeIdempotentAction(
    route.services,
    route.response,
    sessionId,
    "question-answer",
    payload,
    () => deliverAnswer(route, sessionId, questionId, payload)
  )
  return true
}

const deliverAnswer = async (
  route: RouteContext,
  sessionId: string,
  questionId: string,
  payload: SetQuestionAnswerRequestBody
): Promise<AnswerResult> => {
  const { services } = route
  const answer = questionAnswer(payload)
  const handledByAutomation =
    (await services.mcp?.answerQuestion(sessionId, questionId, answer)) ?? false
  if (!handledByAutomation) {
    const agentSession = await agentSessionFor(route, sessionId)
    await run(services.agents.answerQuestion(agentSession.sessionId, questionId, answer))
  }
  return { outcome: payload.outcome, questionId }
}

interface CancelResult {
  readonly cancelled: true
}

interface ModeResult {
  readonly modeId: string
}

interface AnswerResult {
  readonly outcome: SetQuestionAnswerRequestBody["outcome"]
  readonly questionId: string
}

interface ForcedCancel {
  readonly sessionId: string
  readonly session: SessionSummary
  readonly agentSession: AgentSessionMetadata
  readonly activeItem: TranscriptItem | undefined
  readonly cancelRequestedAt: string
}

const transcriptTailSize = 1

const agentSessionFor = (route: RouteContext, sessionId: string): Promise<AgentSessionMetadata> =>
  ensureAgentSessionFor(route.services, route.fanout, route.config.id, sessionId)

const latestTranscriptPage = (
  services: CodevisorServerServices,
  sessionId: string
): Promise<TranscriptPage> =>
  run(services.db.getTranscriptPage(sessionId, undefined, transcriptTailSize))

const logForcedCancel = (config: CodevisorServerConfig, cancel: ForcedCancel): void => {
  const forcedAt = isoTimestamp()
  console.error(
    JSON.stringify({
      event: "agent_cancel_forced",
      sessionId: cancel.sessionId,
      harnessId: cancel.session.harnessId,
      agentSessionId: cancel.agentSession.sessionId,
      turnId: cancel.activeItem?.turnId,
      providerPhase: "cancelling",
      lastEventType: "durable_transcript_snapshot",
      lastEventAt: cancel.activeItem?.updatedAt,
      cancelRequestedAt: cancel.cancelRequestedAt,
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

const goalUpdate = (payload: SetGoalRequestBody): SetGoalUpdate => ({
  ...(payload.objective === undefined ? {} : { objective: payload.objective }),
  ...(payload.status === undefined ? {} : { status: payload.status }),
  ...("tokenBudget" in payload ? { tokenBudget: payload.tokenBudget ?? null } : {})
})

const questionAnswer = (payload: SetQuestionAnswerRequestBody): QuestionAnswer => ({
  outcome: payload.outcome,
  ...(payload.answers === undefined ? {} : { answers: payload.answers })
})
