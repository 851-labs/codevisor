import { z } from "zod"

import {
  gmailDraft,
  gmailHistoryPage,
  gmailLabelList,
  gmailMessage,
  gmailMessageList,
  gmailProfile,
  gmailThread,
  gmailThreadList,
  gmailWatch,
  noContent
} from "./gmail-api-schemas.js"

export type {
  GmailDraft,
  GmailHistoryPage,
  GmailLabel,
  GmailMessage,
  GmailMessageList,
  GmailPart,
  GmailProfile,
  GmailThread,
  GmailThreadList,
  GmailWatch
} from "./gmail-api-schemas.js"

export type Fetch = (url: string, init: RequestInit) => Promise<Response>

export type MessageFormat = "metadata" | "full"

export interface LabelChange {
  add: ReadonlyArray<string>
  remove: ReadonlyArray<string>
}

export interface Outgoing {
  raw: string
  threadId: string | undefined
}

export interface Page {
  query: string
  maxResults: number
  pageToken: string | undefined
}

export class GmailApiError extends Error {
  constructor(
    readonly status: number,
    message: string
  ) {
    super(message)
  }
}

export const gmailBaseUrl = "https://gmail.googleapis.com/gmail/v1/users/me"

export const metadataHeaders = [
  "From",
  "To",
  "Cc",
  "Reply-To",
  "Subject",
  "Date",
  "Message-ID",
  "References"
]

export const gmailRequestTimeoutMs = 30_000

export const rejectedSignIn =
  "Gmail rejected the sign-in. Sign in again in Settings › Plugins › Gmail."

export const gmailApi = (fetcher: Fetch, accessToken: string) => {
  const call = gmailCaller(fetcher, accessToken)
  return {
    profile: () => call(gmailProfile, "/profile"),
    listMessages: (page: Page) => call(gmailMessageList, `/messages?${pageQuery(page)}`),
    listThreads: (page: Page) => call(gmailThreadList, `/threads?${pageQuery(page)}`),
    message: (id: string, format: MessageFormat) =>
      call(gmailMessage, `/messages/${encodeURIComponent(id)}?${formatQuery(format)}`),
    thread: (id: string, format: MessageFormat) =>
      call(gmailThread, `/threads/${encodeURIComponent(id)}?${formatQuery(format)}`),
    history: (startHistoryId: string, maxResults: number) =>
      call(gmailHistoryPage, `/history?${historyQuery(startHistoryId, maxResults)}`),
    labels: async () => (await call(gmailLabelList, "/labels")).labels,
    draft: (id: string) => call(gmailDraft, `/drafts/${encodeURIComponent(id)}?format=full`),
    createDraft: (outgoing: Outgoing) =>
      call(gmailDraft, "/drafts", { method: "POST", body: { message: message(outgoing) } }),
    updateDraft: (id: string, outgoing: Outgoing) =>
      call(gmailDraft, `/drafts/${encodeURIComponent(id)}`, {
        method: "PUT",
        body: { id, message: message(outgoing) }
      }),
    sendDraft: (id: string) => call(gmailMessage, "/drafts/send", { method: "POST", body: { id } }),
    send: (outgoing: Outgoing) =>
      call(gmailMessage, "/messages/send", { method: "POST", body: message(outgoing) }),
    modifyMessages: (ids: ReadonlyArray<string>, change: LabelChange) =>
      call(noContent, "/messages/batchModify", {
        method: "POST",
        body: { ids, ...labelBody(change) }
      }),
    watch: (topicName: string) =>
      call(gmailWatch, "/watch", {
        method: "POST",
        body: { topicName, labelIds: ["INBOX"], labelFilterBehavior: "INCLUDE" }
      }),
    stop: () => call(noContent, "/stop", { method: "POST", body: {} }),
    modifyThread: (id: string, change: LabelChange) =>
      call(gmailThread, `/threads/${encodeURIComponent(id)}/modify`, {
        method: "POST",
        body: labelBody(change)
      })
  }
}

export type GmailApi = ReturnType<typeof gmailApi>

interface Send {
  method: "POST" | "PUT"
  body: unknown
}

type GmailCaller = <T>(schema: z.ZodType<T>, path: string, send?: Send) => Promise<T>

const gmailCaller =
  (fetcher: Fetch, accessToken: string): GmailCaller =>
  async (schema, path, send) => {
    const response = await fetcher(`${gmailBaseUrl}${path}`, requestInit(accessToken, send))
    const text = await response.text()
    if (!response.ok)
      throw new GmailApiError(response.status, failureMessage(response.status, text))

    return schema.parse(text === "" ? {} : JSON.parse(text))
  }

const requestInit = (accessToken: string, send: Send | undefined): RequestInit => {
  const headers = { Authorization: `Bearer ${accessToken}`, Accept: "application/json" }
  const signal = AbortSignal.timeout(gmailRequestTimeoutMs)
  if (send === undefined) return { method: "GET", headers, signal }

  return {
    method: send.method,
    headers: { ...headers, "Content-Type": "application/json" },
    body: JSON.stringify(send.body),
    signal
  }
}

const failureMessage = (status: number, text: string): string => {
  if (status === unauthorized) return rejectedSignIn

  const reason = upstreamReason(text)
  if (reason === "") return `Gmail returned ${status}`

  return `Gmail returned ${status}: ${reason}`
}

const upstreamReason = (text: string): string => {
  try {
    return upstreamError.parse(JSON.parse(text)).error.message
  } catch {
    return text.slice(0, maxReasonChars)
  }
}

const unauthorized = 401
const maxReasonChars = 300

const upstreamError = z.object({ error: z.object({ message: z.string() }) })

const pageQuery = (page: Page): URLSearchParams =>
  new URLSearchParams({
    q: page.query,
    maxResults: String(page.maxResults),
    ...(page.pageToken === undefined ? {} : { pageToken: page.pageToken })
  })

const formatQuery = (format: MessageFormat): URLSearchParams => {
  const query = new URLSearchParams({ format })
  if (format === "metadata")
    for (const header of metadataHeaders) query.append("metadataHeaders", header)
  return query
}

const historyQuery = (startHistoryId: string, maxResults: number): URLSearchParams =>
  new URLSearchParams({
    startHistoryId,
    historyTypes: "messageAdded",
    labelId: "INBOX",
    maxResults: String(maxResults)
  })

const message = (outgoing: Outgoing) => ({
  raw: outgoing.raw,
  ...(outgoing.threadId === undefined ? {} : { threadId: outgoing.threadId })
})

const labelBody = (change: LabelChange) => ({
  addLabelIds: change.add,
  removeLabelIds: change.remove
})
