import { accountMeta, ingressMeta } from "@codevisor/plugin-kit"
import {
  anyResult,
  type ConnectedClient,
  connectClient,
  manualClock,
  openStream
} from "@codevisor/plugin-kit/test-support"
import { onTestFinished } from "vitest"
import { z } from "zod"

import type { Fetch } from "./gmail-api.js"
import { createGmailServer } from "./gmail-server.js"

export interface FakeMessageInput {
  id: string
  threadId?: string | undefined
  from?: string
  to?: string
  cc?: string
  bcc?: string
  replyTo?: string
  subject?: string
  messageIdHeader?: string
  inReplyTo?: string
  references?: string
  labels?: Array<string>
  text?: string
  html?: string
  attachments?: Array<{ filename: string; mimeType: string; size: number }>
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
  watches: Array<Record<string, unknown> | undefined>
  stops: number
  outbox: Array<OutboxEntry>
  add(input: FakeMessageInput): void
  addDraft(draftId: string, input: FakeMessageInput): void
  remove(id: string): void
  labelsOf(id: string): Array<string> | undefined
  expireHistoryThrough(historyId: number): void
  failNext(status: number, body?: string): void
}

export const gmailAccessToken = "ya29.test-token"
export const gmailIdentity = "me@example.com"
export const baseTime = Date.parse("2026-10-27T12:00:00.000Z")

export const fakeLabels = [
  { id: "INBOX", name: "INBOX", type: "system" },
  { id: "UNREAD", name: "UNREAD", type: "system" },
  { id: "STARRED", name: "STARRED", type: "system" },
  { id: "Label_1", name: "Receipts", type: "user" }
]

export const accountFor = (accessToken = gmailAccessToken, identity = gmailIdentity) => ({
  [accountMeta]: {
    id: "acct-1",
    label: "Work",
    identity,
    accessToken,
    fields: {}
  }
})

export const pushTopic = "projects/codevisor-test/topics/gmail"

export const pushMeta = (accessToken = gmailAccessToken, identity = gmailIdentity) => ({
  ...accountFor(accessToken, identity),
  [ingressMeta]: {
    ingress: [
      { name: "other", url: "https://in.example/i/other" },
      { name: "gmail", url: "https://in.example/i/1", route: { name: "gmail", topic: pushTopic } }
    ]
  }
})

export const connectGmail = async (gmail: FakeGmail = fakeGmail()) => {
  const clock = manualClock(baseTime + 60_000)
  const connected = await connectClient(createGmailServer({ fetch: gmail.fetch, clock }))
  onTestFinished(() => connected.client.close())
  return { ...connected, gmail, clock }
}

export const openGmailStream = (
  connected: ConnectedClient,
  cursor: string | null,
  meta: Record<string, unknown> = pushMeta(),
  signal?: AbortSignal
) => openStream(connected, { name: "message.received", arguments: {}, cursor, _meta: meta }, signal)

export const ping = (
  connected: ConnectedClient,
  notification: unknown,
  meta: Record<string, unknown> = accountFor(),
  ingress = "gmail"
) =>
  connected.client.request(
    {
      method: "codevisor/webhook",
      params: {
        ingress,
        request: {
          method: "POST",
          headers: {},
          body: Buffer.from(JSON.stringify(notification)).toString("base64"),
          receivedAt: "2026-10-27T12:01:00.000Z"
        },
        _meta: meta
      }
    },
    anyResult
  )

export const callTool = (
  connected: ConnectedClient,
  name: string,
  args: Record<string, unknown>,
  meta: Record<string, unknown> = accountFor()
) => connected.client.callTool({ name, arguments: args, _meta: meta })

export const decodedMessage = (raw: string): string =>
  Buffer.from(raw, "base64url").toString("utf8")

export const bodyOf = (message: string): string =>
  Buffer.from((message.split("\r\n\r\n")[1] ?? "").replaceAll("\r\n", ""), "base64").toString(
    "utf8"
  )

export const fakeGmail = (): FakeGmail => {
  const state: FakeState = {
    messages: new Map(),
    drafts: new Map(),
    history: [],
    historyId: 1000,
    expiredThrough: 0,
    failures: []
  }
  const requests: Array<FakeRequest> = []
  const outbox: Array<OutboxEntry> = []
  const fake: FakeGmail = {
    requests,
    outbox,
    watches: [],
    stops: 0,
    fetch: async (url, init) => {
      const request = {
        method: String(init.method),
        url: new URL(url),
        body: parsedBody(init.body)
      }
      requests.push(request)
      const response = respond({ state, outbox }, request, init)
      if (response.ok && request.url.pathname.endsWith("/watch")) fake.watches.push(request.body)
      if (response.ok && request.url.pathname.endsWith("/stop")) fake.stops += 1
      return response
    },
    add: (input) => addMessage(state, gmailMessage(input)),
    addDraft: (draftId, input) => state.drafts.set(draftId, gmailMessage(input)),
    remove: (id) => state.messages.delete(id),
    labelsOf: (id) => state.messages.get(id)?.labelIds,
    expireHistoryThrough: (historyId) => {
      state.expiredThrough = historyId
    },
    failNext: (status: number, body?: string) => state.failures.push({ status, body })
  }
  return fake
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
  drafts: Map<string, FakeMessage>
  history: Array<{ id: string; messageId: string }>
  historyId: number
  expiredThrough: number
  failures: Array<{ status: number; body: string | undefined }>
}

interface Mailbox {
  state: FakeState
  outbox: Array<OutboxEntry>
}

type Route = (mailbox: Mailbox, request: FakeRequest, parts: Array<string>) => Response

const respond = (mailbox: Mailbox, request: FakeRequest, init: RequestInit): Response => {
  const failure = mailbox.state.failures.shift()
  if (failure !== undefined) return failed(failure)
  if (new Headers(init.headers).get("Authorization") !== `Bearer ${gmailAccessToken}`)
    return json(401, { error: { code: 401, message: "Invalid Credentials" } })

  const parts = request.url.pathname
    .replace(apiPrefix, "")
    .split("/")
    .filter((part) => part !== "")
  return routes[String(parts[0])]?.(mailbox, request, parts) ?? json(404, {})
}

const apiPrefix = "/gmail/v1/users/me"
const weekMs = 7 * 24 * 60 * 60_000

const failed = (failure: { status: number; body: string | undefined }): Response =>
  new Response(
    failure.body ?? JSON.stringify({ error: { code: failure.status, message: "Backend Error" } }),
    {
      status: failure.status
    }
  )

const routes: Readonly<Record<string, Route>> = {
  watch: ({ state }) =>
    json(200, { historyId: String(state.historyId), expiration: String(baseTime + weekMs) }),
  stop: () => new Response(null, { status: 204 }),
  profile: ({ state }) =>
    json(200, { emailAddress: gmailIdentity, historyId: String(state.historyId) }),
  history: ({ state }, request) => historyPage(state, request.url.searchParams),
  labels: () => json(200, { labels: fakeLabels }),
  threads: ({ state }, request, [, id, action]) => {
    if (id === undefined) return threadList(state, request.url.searchParams)
    if (action === "modify") return modifiedThread(state, id, request.body)
    return thread(state, id)
  },
  drafts: (mailbox, request, [, id]) => {
    if (id === "send") return sentDraft(mailbox, request.body)
    if (id === undefined) return draft(mailbox.outbox, request.body)
    if (request.method === "PUT") return draft(mailbox.outbox, request.body, id)
    return storedDraft(mailbox.state, id)
  },
  messages: (mailbox, request, [, id]) => {
    if (id === "send") return sent(mailbox, request.body)
    if (id === "batchModify") return batchModified(mailbox.state, request.body)
    if (id === undefined) return messageList(mailbox.state, request.url.searchParams)
    return found(mailbox.state.messages.get(id))
  }
}

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

const threadMessages = (state: FakeState, threadId: string): Array<FakeMessage> =>
  [...state.messages.values()].filter((message) => message.threadId === threadId)

const thread = (state: FakeState, threadId: string): Response =>
  json(200, { id: threadId, messages: threadMessages(state, threadId) })

const threadList = (state: FakeState, query: URLSearchParams): Response => {
  const ids = [...new Set([...state.messages.values()].map((message) => message.threadId))]
  return json(
    200,
    pageOf(
      ids.toReversed().map((id) => ({ id })),
      query,
      "threads"
    )
  )
}

const messageList = (state: FakeState, query: URLSearchParams): Response => {
  const messages = [...state.messages.values()].toReversed()
  return json(
    200,
    pageOf(
      messages.map((message) => ({ id: message.id, threadId: message.threadId })),
      query,
      "messages"
    )
  )
}

const pageOf = (items: Array<unknown>, query: URLSearchParams, key: string) => {
  const start = Number(query.get("pageToken") ?? 0)
  const end = start + Number(query.get("maxResults"))
  return {
    [key]: items.slice(start, end),
    ...(end < items.length ? { nextPageToken: String(end) } : {})
  }
}

const found = (message: FakeMessage | undefined): Response => {
  if (message === undefined) return json(404, { error: { code: 404, message: "Not Found" } })

  return json(200, message)
}

const storedDraft = (state: FakeState, id: string): Response => {
  const message = state.drafts.get(id)
  if (message === undefined) return json(404, { error: { code: 404, message: "Not Found" } })

  return json(200, { id, message })
}

const draft = (
  outbox: Array<OutboxEntry>,
  body: Record<string, unknown> | undefined,
  id?: string
): Response => {
  const message = outgoingOf(draftBody.parse(body).message)
  outbox.push({ kind: "draft", ...message })
  return json(200, {
    id: id ?? `r-${outbox.length}`,
    message: {
      id: `draft-${outbox.length}`,
      threadId: message.threadId ?? `draft-${outbox.length}`
    }
  })
}

const sent = (mailbox: Mailbox, body: Record<string, unknown> | undefined): Response => {
  const message = outgoingOf(body)
  mailbox.outbox.push({ kind: "send", ...message })
  return json(200, storeSent(mailbox, message.threadId))
}

const sentDraft = (mailbox: Mailbox, body: Record<string, unknown> | undefined): Response => {
  const { id } = z.object({ id: z.string() }).parse(body)
  const stored = mailbox.state.drafts.get(id)
  if (stored === undefined) return json(404, { error: { code: 404, message: "Not Found" } })

  mailbox.state.drafts.delete(id)
  mailbox.outbox.push({ kind: "send", threadId: stored.threadId, message: `draft ${id}` })
  return json(200, storeSent(mailbox, stored.threadId))
}

const storeSent = (mailbox: Mailbox, threadId: string | undefined): FakeMessage => {
  const stored = gmailMessage({
    id: `sent-${mailbox.outbox.length}`,
    threadId,
    from: gmailIdentity,
    labels: ["SENT"]
  })
  addMessage(mailbox.state, stored)
  return stored
}

const batchModified = (state: FakeState, body: Record<string, unknown> | undefined): Response => {
  const { ids, ...change } = batchChange.parse(body)
  for (const id of ids) relabel(state.messages.get(id), change)
  return new Response(null, { status: 204 })
}

const modifiedThread = (
  state: FakeState,
  threadId: string,
  body: Record<string, unknown> | undefined
): Response => {
  const change = labelChange.parse(body)
  for (const message of threadMessages(state, threadId)) relabel(message, change)
  return thread(state, threadId)
}

const relabel = (
  message: FakeMessage | undefined,
  change: { addLabelIds: Array<string>; removeLabelIds: Array<string> }
): void => {
  if (message === undefined) return

  message.labelIds = [
    ...message.labelIds.filter((label) => !change.removeLabelIds.includes(label)),
    ...change.addLabelIds
  ]
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
  payload: { mimeType: "multipart/mixed", headers: headersOf(input), parts: bodyParts(input) }
})

const headersOf = (input: FakeMessageInput): Array<{ name: string; value: string }> =>
  (
    [
      ["From", input.from],
      ["To", input.to],
      ["Cc", input.cc],
      ["Bcc", input.bcc],
      ["Reply-To", input.replyTo],
      ["Subject", input.subject],
      ["Message-ID", input.messageIdHeader],
      ["In-Reply-To", input.inReplyTo],
      ["References", input.references]
    ] as const
  ).flatMap(([name, value]) => (value === undefined ? [] : [{ name, value }]))

const bodyParts = (input: FakeMessageInput): Array<Record<string, unknown>> => [
  ...(
    [
      ["text/plain", input.text],
      ["text/html", input.html]
    ] as const
  ).flatMap(([mimeType, text]) =>
    text === undefined
      ? []
      : [{ mimeType, body: { data: Buffer.from(text, "utf8").toString("base64url") } }]
  ),
  ...(input.attachments ?? []).map((attachment) => ({
    mimeType: attachment.mimeType,
    filename: attachment.filename,
    body: { attachmentId: "att", size: attachment.size }
  }))
]

const outgoingOf = (value: unknown): { threadId: string | undefined; message: string } => {
  const outgoing = outgoingMessage.parse(value)
  return { threadId: outgoing.threadId, message: decodedMessage(outgoing.raw) }
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
const batchChange = labelChange.extend({ ids: z.array(z.string()) })

const json = (status: number, body: unknown): Response =>
  new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } })
