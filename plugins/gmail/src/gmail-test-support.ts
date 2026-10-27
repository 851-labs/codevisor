import { z } from "zod"

import type { Fetch } from "./gmail-api.js"

export interface FakeMessageInput {
  id: string
  threadId?: string | undefined
  from?: string
  to?: string
  cc?: string
  subject?: string
  messageIdHeader?: string
  references?: string
  labels?: Array<string>
  text?: string
  html?: string
  internalDate?: number
}

export interface OutboxEntry {
  kind: "draft" | "send"
  threadId: string | undefined
  message: string
}

export interface FakeRequest {
  method: string
  url: URL
  body: Record<string, unknown> | undefined
}

export interface FakeGmail {
  fetch: Fetch
  requests: Array<FakeRequest>
  outbox: Array<OutboxEntry>
  add(input: FakeMessageInput): void
  remove(id: string): void
  labelsOf(id: string): Array<string> | undefined
  expireHistoryThrough(historyId: number): void
  failNext(status: number): void
}

export const gmailAccessToken = "ya29.test-token"
export const gmailIdentity = "me@example.com"
export const baseTime = Date.parse("2026-10-27T12:00:00.000Z")

export const fakeGmail = (): FakeGmail => {
  const state: FakeState = {
    messages: new Map(),
    history: [],
    historyId: 1000,
    expiredThrough: 0,
    failures: []
  }
  const requests: Array<FakeRequest> = []
  const outbox: Array<OutboxEntry> = []
  return {
    requests,
    outbox,
    fetch: async (url, init) => {
      const request = {
        method: String(init.method),
        url: new URL(url),
        body: parsedBody(init.body)
      }
      requests.push(request)
      return respond(state, outbox, request, init)
    },
    add: (input) => addMessage(state, gmailMessage(input)),
    remove: (id) => state.messages.delete(id),
    labelsOf: (id) => state.messages.get(id)?.labelIds,
    expireHistoryThrough: (historyId) => {
      state.expiredThrough = historyId
    },
    failNext: (status) => state.failures.push(status)
  }
}

interface FakeMessage {
  id: string
  threadId: string
  labelIds: Array<string>
  snippet: string
  internalDate: string
  payload: Record<string, unknown>
}

interface FakeState {
  messages: Map<string, FakeMessage>
  history: Array<{ id: string; messageId: string }>
  historyId: number
  expiredThrough: number
  failures: Array<number>
}

const respond = (
  state: FakeState,
  outbox: Array<OutboxEntry>,
  request: FakeRequest,
  init: RequestInit
): Response => {
  const failure = state.failures.shift()
  if (failure !== undefined) return json(failure, { error: { code: failure } })
  if (new Headers(init.headers).get("Authorization") !== `Bearer ${gmailAccessToken}`)
    return json(401, {})

  const [collection, id, action] = request.url.pathname
    .replace(apiPrefix, "")
    .split("/")
    .filter((part) => part !== "")
  if (collection === "profile")
    return json(200, { emailAddress: gmailIdentity, historyId: String(state.historyId) })
  if (collection === "history") return historyPage(state, request.url.searchParams)
  if (collection === "threads") return thread(state, String(id))
  if (collection === "drafts") return draft(outbox, request.body)
  if (id === "send") return sent(state, outbox, request.body)
  if (action === "modify") return modified(state, String(id), request.body)
  if (id === undefined) return messageList(state, request.url.searchParams)

  return found(state.messages.get(id))
}

const apiPrefix = "/gmail/v1/users/me"

const historyPage = (state: FakeState, query: URLSearchParams): Response => {
  const start = Number(query.get("startHistoryId"))
  if (start <= state.expiredThrough)
    return json(404, { error: { code: 404, message: "Requested entity was not found." } })

  const pending = state.history.filter((record) => Number(record.id) > start)
  const page = pending.slice(0, Number(query.get("maxResults")))
  return json(200, {
    history: page.map((record) => ({
      id: record.id,
      messagesAdded: [{ message: { id: record.messageId } }]
    })),
    historyId: String(state.historyId),
    ...(pending.length > page.length ? { nextPageToken: "next" } : {})
  })
}

const thread = (state: FakeState, threadId: string): Response =>
  json(200, {
    id: threadId,
    messages: [...state.messages.values()].filter((message) => message.threadId === threadId)
  })

const messageList = (state: FakeState, query: URLSearchParams): Response => {
  const messages = [...state.messages.values()]
    .toReversed()
    .slice(0, Number(query.get("maxResults")))
  return json(200, {
    messages: messages.map((message) => ({ id: message.id, threadId: message.threadId }))
  })
}

const found = (message: FakeMessage | undefined): Response => {
  if (message === undefined) return json(404, { error: { code: 404 } })

  return json(200, message)
}

const draft = (outbox: Array<OutboxEntry>, body: Record<string, unknown> | undefined): Response => {
  const message = outgoingOf(draftBody.parse(body).message)
  outbox.push({ kind: "draft", ...message })
  return json(200, {
    id: `r-${outbox.length}`,
    message: { id: `draft-${outbox.length}`, threadId: message.threadId }
  })
}

const sent = (
  state: FakeState,
  outbox: Array<OutboxEntry>,
  body: Record<string, unknown> | undefined
): Response => {
  const message = outgoingOf(body)
  outbox.push({ kind: "send", ...message })
  const stored = gmailMessage({
    id: `sent-${outbox.length}`,
    threadId: message.threadId,
    from: gmailIdentity,
    labels: ["SENT"]
  })
  addMessage(state, stored)
  return json(200, stored)
}

const modified = (
  state: FakeState,
  id: string,
  body: Record<string, unknown> | undefined
): Response => {
  const message = state.messages.get(id)
  if (message === undefined) return json(404, { error: { code: 404 } })

  const { addLabelIds: add, removeLabelIds: remove } = labelChange.parse(body)
  message.labelIds = [...message.labelIds.filter((label) => !remove.includes(label)), ...add]
  return json(200, message)
}

const addMessage = (state: FakeState, message: FakeMessage): void => {
  state.messages.set(message.id, message)
  state.historyId += 1
  state.history.push({ id: String(state.historyId), messageId: message.id })
}

const gmailMessage = (input: FakeMessageInput): FakeMessage => ({
  id: input.id,
  threadId: input.threadId ?? input.id,
  labelIds: input.labels ?? ["INBOX", "UNREAD"],
  snippet: (input.text ?? "").slice(0, 40),
  internalDate: String(input.internalDate ?? baseTime),
  payload: { mimeType: "multipart/alternative", headers: headersOf(input), parts: bodyParts(input) }
})

const headersOf = (input: FakeMessageInput): Array<{ name: string; value: string }> =>
  (
    [
      ["From", input.from],
      ["To", input.to],
      ["Cc", input.cc],
      ["Subject", input.subject],
      ["Message-ID", input.messageIdHeader],
      ["References", input.references]
    ] as const
  ).flatMap(([name, value]) => (value === undefined ? [] : [{ name, value }]))

const bodyParts = (input: FakeMessageInput): Array<Record<string, unknown>> =>
  (
    [
      ["text/plain", input.text],
      ["text/html", input.html]
    ] as const
  ).flatMap(([mimeType, text]) =>
    text === undefined
      ? []
      : [{ mimeType, body: { data: Buffer.from(text, "utf8").toString("base64url") } }]
  )

const outgoingOf = (value: unknown): { threadId: string | undefined; message: string } => {
  const outgoing = outgoingMessage.parse(value)
  return {
    threadId: outgoing.threadId,
    message: Buffer.from(outgoing.raw, "base64url").toString("utf8")
  }
}

const parsedBody = (body: RequestInit["body"]): Record<string, unknown> | undefined => {
  if (typeof body !== "string") return undefined

  return z.record(z.string(), z.unknown()).parse(JSON.parse(body))
}

const outgoingMessage = z.object({ raw: z.string(), threadId: z.string().optional() })
const draftBody = z.object({ message: outgoingMessage })
const labelChange = z.object({
  addLabelIds: z.array(z.string()),
  removeLabelIds: z.array(z.string())
})

const json = (status: number, body: unknown): Response =>
  new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } })
