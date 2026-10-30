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
import { captureMarkdownFiles } from "./assistant-artifacts.js"
import { captureAssistantFile } from "./assistant-files.js"
import { conversationalBotForSession, postBotMessage } from "./bot-turns.js"
import { hasLiveTurn } from "./prompt-queue.js"
import { attribute } from "./session-event-messages.js"

const PAGE_LIMIT = 50
const MAX_PAGE_LIMIT = 200

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
        if (attachments.some((candidate) => candidate.fileId === file.fileId)) continue
        attachments.push(input.name === undefined ? file : { ...file, name: input.name })
      } catch (cause) {
        throw new HttpFailure(422, `Could not attach ${input.path}: ${failureMessage(cause)}`)
      }
    }
    const { cwd } = await run(services.db.getSessionSummary(messagesSessionId))
    const captured = await captureMarkdownFiles(services, text, cwd, attachments)
    const message = await postBotMessage(services, fanout, messagesSessionId, {
      sender: "bot",
      text: captured.markdown,
      ...(captured.attachments.length === 0 ? {} : { attachments: captured.attachments })
    })
    writeJson(response, 200, { sent: true, messageId: message.id })
    return true
  }

  return false
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

export const makeBotConversationListener = (
  services: CodevisorServerServices,
  fanout: EventFanout
) => {
  const serialized = makeSessionChains()
  return (event: EventEnvelope): void => {
    const notice = turnNotice(event)
    if (notice === undefined) return

    const sessionId = event.subjectId
    void serialized(sessionId, () => postBotNotice(services, fanout, sessionId, notice))
  }
}

const turnNotice = (event: EventEnvelope): string | undefined => {
  const payload = isRecord(event.payload) ? event.payload : {}
  if (event.kind === "session.error") return `Couldn't reply: ${String(payload.message)}`
  if (event.kind !== "session.updated" || payload.turnState !== "ended") return undefined

  return stopNotice(payload)
}

const stopNotice = (payload: Record<string, unknown>): string | undefined => {
  if (payload.stopKind === "usageLimit") return undefined
  return typeof payload.stopDetail === "string" ? payload.stopDetail : undefined
}

const postBotNotice = async (
  services: CodevisorServerServices,
  fanout: EventFanout,
  sessionId: string,
  text: string
): Promise<void> => {
  if ((await conversationalBotForSession(services, sessionId)) === undefined) return
  if (await repeatsLatestMessage(services, sessionId, text)) return

  await postBotMessage(services, fanout, sessionId, { sender: "notice", text })
}

const repeatsLatestMessage = async (
  services: CodevisorServerServices,
  sessionId: string,
  text: string
): Promise<boolean> => {
  const [latest] = (await run(services.db.listBotMessages(sessionId, undefined, 1))).messages
  return latest?.sender === "notice" && latest.text === text
}

const makeSessionChains = () => {
  const chains = new Map<string, Promise<void>>()
  return (sessionId: string, step: () => Promise<void>): Promise<void> => {
    const next = (chains.get(sessionId) ?? Promise.resolve()).then(step).catch(swallowError)
    chains.set(sessionId, next)
    return next
  }
}
