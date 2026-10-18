import type { IncomingMessage, ServerResponse } from "node:http"
import { isAbsolute } from "node:path"

import type { AttachmentRef, BotConversationPage, EventEnvelope } from "@codevisor/api"
import { SendBotMessageRequest } from "@codevisor/api"

import {
  failureMessage,
  HttpFailure,
  matchRoute,
  readSchema,
  run,
  swallowError,
  writeJson,
  type CodevisorServerServices,
  type EventFanout,
  type RouteState
} from "../server-context.js"
import { isRecord } from "../unknown-values.js"
import { captureAssistantFile } from "./assistant-files.js"
import { conversationalBotForSession, postBotMessage, takeBotTurn } from "./bot-turns.js"
import { drainPromptQueue, hasLiveTurn } from "./prompt-queue.js"

const PAGE_LIMIT = 50
const MAX_PAGE_LIMIT = 200
const CHILD_REPORT_LIMIT = 4_000

const requireBotSession = async (
  services: CodevisorServerServices,
  sessionId: string
): Promise<void> => {
  if ((await conversationalBotForSession(services, sessionId)) === undefined) {
    throw new HttpFailure(403, "Only a conversational bot's own chat can send messages to the user")
  }
}

const pageLimit = (raw: string | null): number => {
  const parsed = raw === null ? PAGE_LIMIT : Number.parseInt(raw, 10)
  return Number.isFinite(parsed) && parsed > 0 ? Math.min(parsed, MAX_PAGE_LIMIT) : PAGE_LIMIT
}

const pageBefore = (raw: string | null): number | undefined => {
  if (raw === null) return undefined
  const parsed = Number.parseInt(raw, 10)
  return Number.isFinite(parsed) ? parsed : undefined
}

export const routeBotConversation = async (
  services: CodevisorServerServices,
  fanout: EventFanout,
  routeState: RouteState,
  request: IncomingMessage,
  response: ServerResponse,
  url: URL
): Promise<boolean> => {
  const conversationSessionId = matchRoute(url.pathname, "/v1/sessions/:id/conversation")
  if (conversationSessionId !== undefined && request.method === "GET") {
    const page = await run(
      services.db.listBotMessages(
        conversationSessionId,
        pageBefore(url.searchParams.get("before")),
        pageLimit(url.searchParams.get("limit"))
      )
    )
    const body: BotConversationPage = {
      ...page,
      working: hasLiveTurn(routeState, conversationSessionId)
    }
    writeJson(response, 200, body)
    return true
  }

  const messagesSessionId = matchRoute(url.pathname, "/v1/sessions/:id/messages")
  if (messagesSessionId !== undefined && request.method === "POST") {
    await requireBotSession(services, messagesSessionId)
    const payload = await readSchema(request, SendBotMessageRequest)
    const text = payload.text.trim()
    const inputs = payload.attachments ?? []
    if (text.length === 0 && inputs.length === 0) {
      throw new HttpFailure(422, "A message needs text or an attachment")
    }
    const attachments: Array<AttachmentRef> = []
    for (const input of inputs) {
      if (!isAbsolute(input.path)) {
        throw new HttpFailure(422, `Attachment paths must be absolute: ${input.path}`)
      }
      try {
        const file = await captureAssistantFile(services, { path: input.path }, attachments)
        attachments.push(input.name === undefined ? file : { ...file, name: input.name })
      } catch (cause) {
        throw new HttpFailure(422, `Could not attach ${input.path}: ${failureMessage(cause)}`)
      }
    }
    const message = await postBotMessage(services, fanout, messagesSessionId, {
      sender: "bot",
      text,
      ...(attachments.length === 0 ? {} : { attachments })
    })
    writeJson(response, 200, { sent: true, messageId: message.id })
    return true
  }

  return false
}

const finalAssistantText = async (
  services: CodevisorServerServices,
  sessionId: string
): Promise<{ readonly text: string; readonly attachments?: ReadonlyArray<AttachmentRef> }> => {
  const page = await run(services.db.getTranscriptPage(sessionId, undefined, 8))
  const item = [...page.items].toReversed().find((candidate) => candidate.role === "assistant")
  return {
    text: item?.text.trim() ?? "",
    ...(item?.attachments === undefined ? {} : { attachments: item.attachments })
  }
}

const attribute = (value: string): string =>
  value.replaceAll("&", "&amp;").replaceAll('"', "&quot;").replaceAll("<", "&lt;")

const childReport = (
  childId: string,
  title: string,
  stopReason: string | undefined,
  text: string
): string => {
  const body =
    text.length > CHILD_REPORT_LIMIT ? `${text.slice(0, CHILD_REPORT_LIMIT)}\n…(truncated)` : text
  const stop = stopReason === undefined ? "" : ` stopReason="${attribute(stopReason)}"`
  return [
    `<codevisor-event type="session.turn_ended" sessionId="${attribute(childId)}" title="${attribute(title)}"${stop}>`,
    body.length === 0 ? "(no final message)" : body,
    "</codevisor-event>"
  ].join("\n")
}

export const agentMessageEvent = async (
  services: CodevisorServerServices,
  fromSessionId: string,
  text: string
): Promise<string> => {
  const sender = await run(services.db.getSessionSummary(fromSessionId)).catch(() => undefined)
  const title = sender === undefined ? "" : ` title="${attribute(sender.title)}"`
  return [
    `<codevisor-event type="session.message" from="${attribute(fromSessionId)}"${title}>`,
    text,
    "</codevisor-event>"
  ].join("\n")
}

const settleBotTurn = async (
  services: CodevisorServerServices,
  fanout: EventFanout,
  sessionId: string,
  turn: ReturnType<typeof takeBotTurn>,
  payload: Record<string, unknown>
): Promise<void> => {
  if (typeof payload.stopKind === "string" && typeof payload.stopDetail === "string") {
    await postBotMessage(services, fanout, sessionId, {
      sender: "notice",
      text: payload.stopDetail
    })
    return
  }
  if (turn === undefined || !turn.userPrompted || turn.sent) return
  if (payload.stopReason === "cancelled") return
  const final = await finalAssistantText(services, sessionId)
  if (final.text.length === 0 && final.attachments === undefined) return
  await postBotMessage(services, fanout, sessionId, {
    sender: "bot",
    text: final.text,
    ...(final.attachments === undefined ? {} : { attachments: final.attachments })
  })
}

const reportChildTurn = async (
  services: CodevisorServerServices,
  fanout: EventFanout,
  routeState: RouteState,
  serverId: string,
  childId: string,
  payload: Record<string, unknown>
): Promise<void> => {
  const child = await run(services.db.getSessionSummary(childId))
  const parentId = child.parentSessionId
  if (
    parentId === undefined ||
    (await conversationalBotForSession(services, parentId)) === undefined
  )
    return
  const final = await finalAssistantText(services, childId)
  const report = childReport(
    child.id,
    child.title,
    typeof payload.stopReason === "string" ? payload.stopReason : undefined,
    final.text
  )
  await run(services.db.createPromptQueueItem(parentId, report, [], undefined, undefined, "system"))
  await drainPromptQueue(services, fanout, routeState, serverId, parentId)
}

export const makeBotConversationListener =
  (
    services: CodevisorServerServices,
    fanout: EventFanout,
    routeState: RouteState,
    serverId: string
  ) =>
  (event: EventEnvelope): void => {
    const payload = isRecord(event.payload) ? event.payload : {}
    if (event.kind === "session.error") {
      const message = String(payload.message)
      void (async () => {
        if ((await conversationalBotForSession(services, event.subjectId)) === undefined) return
        takeBotTurn(services, event.subjectId)
        await postBotMessage(services, fanout, event.subjectId, {
          sender: "notice",
          text: `Couldn't reply: ${message}`
        })
      })().catch(swallowError)
      return
    }
    if (event.kind !== "session.updated" || payload.turnState !== "ended") return
    const turn = takeBotTurn(services, event.subjectId)
    void (async () => {
      if ((await conversationalBotForSession(services, event.subjectId)) !== undefined) {
        await settleBotTurn(services, fanout, event.subjectId, turn, payload)
        return
      }
      await reportChildTurn(services, fanout, routeState, serverId, event.subjectId, payload)
    })().catch(swallowError)
  }
