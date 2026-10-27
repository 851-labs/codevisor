import { z } from "zod"

export type Fetch = (url: string, init: RequestInit) => Promise<Response>

export interface GmailPart {
  mimeType?: string | undefined
  headers?: Array<{ name: string; value: string }> | undefined
  body?: { data?: string | undefined } | undefined
  parts?: Array<GmailPart> | undefined
}

export type GmailMessage = z.infer<typeof gmailMessage>
export type GmailThread = z.infer<typeof gmailThread>
export type GmailProfile = z.infer<typeof gmailProfile>
export type GmailHistoryPage = z.infer<typeof gmailHistoryPage>
export type GmailDraft = z.infer<typeof gmailDraft>
export type MessageFormat = "metadata" | "full"

export interface GmailApi {
  profile(): Promise<GmailProfile>
  listMessages(query: string, maxResults: number): Promise<ReadonlyArray<{ id: string }>>
  message(id: string, format: MessageFormat): Promise<GmailMessage>
  thread(id: string): Promise<GmailThread>
  history(startHistoryId: string, maxResults: number): Promise<GmailHistoryPage>
  createDraft(raw: string, threadId: string | undefined): Promise<GmailDraft>
  send(raw: string, threadId: string | undefined): Promise<GmailMessage>
  modifyLabels(
    id: string,
    add: ReadonlyArray<string>,
    remove: ReadonlyArray<string>
  ): Promise<GmailMessage>
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

export const metadataHeaders = ["From", "To", "Cc", "Subject", "Date", "Message-ID", "References"]

export const gmailApi = (fetcher: Fetch, accessToken: string): GmailApi => {
  const call = gmailCaller(fetcher, accessToken)
  return {
    profile: () => call(gmailProfile, "/profile"),
    listMessages: async (query, maxResults) =>
      (
        await call(
          gmailMessageList,
          `/messages?${new URLSearchParams({ q: query, maxResults: String(maxResults) })}`
        )
      ).messages,
    message: (id, format) =>
      call(gmailMessage, `/messages/${encodeURIComponent(id)}?${formatQuery(format)}`),
    thread: (id) => call(gmailThread, `/threads/${encodeURIComponent(id)}?format=full`),
    history: (startHistoryId, maxResults) =>
      call(gmailHistoryPage, `/history?${historyQuery(startHistoryId, maxResults)}`),
    createDraft: (raw, threadId) =>
      call(gmailDraft, "/drafts", { message: outgoing(raw, threadId) }),
    send: (raw, threadId) => call(gmailMessage, "/messages/send", outgoing(raw, threadId)),
    modifyLabels: (id, add, remove) =>
      call(gmailMessage, `/messages/${encodeURIComponent(id)}/modify`, {
        addLabelIds: add,
        removeLabelIds: remove
      })
  }
}

type GmailCaller = <T>(schema: z.ZodType<T>, path: string, body?: unknown) => Promise<T>

const gmailCaller =
  (fetcher: Fetch, accessToken: string): GmailCaller =>
  async (schema, path, body) => {
    const response = await fetcher(`${gmailBaseUrl}${path}`, requestInit(accessToken, body))
    const text = await response.text()
    if (!response.ok)
      throw new GmailApiError(response.status, `Gmail returned ${response.status}: ${text}`)

    return schema.parse(JSON.parse(text))
  }

const requestInit = (accessToken: string, body: unknown): RequestInit => {
  const headers = { Authorization: `Bearer ${accessToken}`, Accept: "application/json" }
  if (body === undefined) return { method: "GET", headers }

  return {
    method: "POST",
    headers: { ...headers, "Content-Type": "application/json" },
    body: JSON.stringify(body)
  }
}

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

const outgoing = (raw: string, threadId: string | undefined) => ({
  raw,
  ...(threadId === undefined ? {} : { threadId })
})

const gmailPart: z.ZodType<GmailPart> = z.lazy(() =>
  z.object({
    mimeType: z.string().optional(),
    headers: z.array(z.object({ name: z.string(), value: z.string() })).optional(),
    body: z.object({ data: z.string().optional() }).optional(),
    parts: z.array(gmailPart).optional()
  })
)

const gmailMessage = z.object({
  id: z.string(),
  threadId: z.string(),
  labelIds: z.array(z.string()).default([]),
  snippet: z.string().default(""),
  internalDate: z.string().default("0"),
  payload: gmailPart.default({})
})

const gmailMessageList = z.object({
  messages: z.array(z.object({ id: z.string() })).default([])
})

const gmailThread = z.object({
  id: z.string(),
  messages: z.array(gmailMessage).default([])
})

const gmailProfile = z.object({ emailAddress: z.string(), historyId: z.string() })

const gmailHistoryPage = z.object({
  history: z
    .array(
      z.object({
        id: z.string(),
        messagesAdded: z.array(z.object({ message: z.object({ id: z.string() }) })).default([])
      })
    )
    .default([]),
  historyId: z.string(),
  nextPageToken: z.string().optional()
})

const gmailDraft = z.object({
  id: z.string(),
  message: z.object({ id: z.string(), threadId: z.string().optional() })
})
