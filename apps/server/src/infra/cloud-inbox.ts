import type { HubInboxItem } from "@codevisor/api"
import { openInboxItem } from "@codevisor/cloud-client"

export interface InboxWebhookRequest {
  readonly itemId: string
  readonly inboxId: string
  readonly method: string
  readonly headers: Readonly<Record<string, string>>
  readonly body: string
  readonly receivedAt: string
}

export interface InboxOAuthCallback {
  readonly flowId: string
  readonly state: string
  readonly code?: string
  readonly error?: string
}

export interface CloudInbox {
  readonly receive: (secretKey: string, frame: HubInboxItem) => Promise<void>
  readonly onWebhook: (handler: (request: InboxWebhookRequest) => Promise<void>) => () => void
  readonly onOAuth: (handler: (callback: InboxOAuthCallback) => Promise<void>) => () => void
}

export const makeCloudInbox = (): CloudInbox => {
  const webhookHandlers = new Set<(request: InboxWebhookRequest) => Promise<void>>()
  const oauthHandlers = new Set<(callback: InboxOAuthCallback) => Promise<void>>()
  const seen = new Set<string>()

  const dispatch = async (frame: HubInboxItem, payload: unknown): Promise<void> => {
    if (frame.kind === "webhook") {
      const request = webhookRequestOf(payload)
      if (request !== undefined) await all(webhookHandlers, request)
      return
    }
    const callback = oauthCallbackOf(payload)
    if (callback !== undefined) await all(oauthHandlers, callback)
  }

  return {
    receive: async (secretKey, frame) => {
      if (seen.has(frame.itemId)) return
      await dispatch(frame, openInboxItem(secretKey, frame))
      remember(seen, frame.itemId)
    },
    onWebhook: (handler) => register(webhookHandlers, handler),
    onOAuth: (handler) => register(oauthHandlers, handler)
  }
}

export const inboxFrameHandler =
  (
    inbox: CloudInbox | undefined,
    secretKey: string,
    ack: (itemIds: ReadonlyArray<string>) => void
  ) =>
  (frame: HubInboxItem): void => {
    if (inbox === undefined) return
    void inbox.receive(secretKey, frame).then(
      () => ack([frame.itemId]),
      () => undefined
    )
  }

const maxRemembered = 2_000

const remember = (seen: Set<string>, itemId: string): void => {
  seen.add(itemId)
  if (seen.size <= maxRemembered) return
  seen.delete(seen.values().next().value!)
}

const register = <T>(handlers: Set<T>, handler: T): (() => void) => {
  handlers.add(handler)
  return () => {
    handlers.delete(handler)
  }
}

const all = async <T>(handlers: ReadonlySet<(value: T) => Promise<void>>, value: T) => {
  await Promise.all([...handlers].map((handler) => handler(value)))
}

const webhookRequestOf = (payload: unknown): InboxWebhookRequest | undefined => {
  if (!isRecord(payload)) return undefined
  const { itemId, inboxId, method, headers, body, receivedAt } = payload
  if (![itemId, inboxId, method, body, receivedAt].every(isString)) return undefined
  return {
    itemId: String(itemId),
    inboxId: String(inboxId),
    method: String(method),
    headers: stringRecord(headers),
    body: String(body),
    receivedAt: String(receivedAt)
  }
}

const oauthCallbackOf = (payload: unknown): InboxOAuthCallback | undefined => {
  if (!isRecord(payload) || !isString(payload.flowId) || !isString(payload.state)) return undefined
  return {
    flowId: payload.flowId,
    state: payload.state,
    ...(isString(payload.code) ? { code: payload.code } : {}),
    ...(isString(payload.error) ? { error: payload.error } : {})
  }
}

const isRecord = (value: unknown): value is Record<string, unknown> =>
  typeof value === "object" && value !== null && !Array.isArray(value)

const isString = (value: unknown): value is string => typeof value === "string"

const stringRecord = (value: unknown): Readonly<Record<string, string>> =>
  isRecord(value)
    ? Object.fromEntries(
        Object.entries(value).filter((pair): pair is [string, string] => isString(pair[1]))
      )
    : {}

export interface MachineApiCall {
  readonly method: string
  readonly path: string
  readonly body?: unknown
}

export const machineApiRequest = async (
  fetchImpl: (input: string, init?: RequestInit) => Promise<Response>,
  credentials: { readonly serverUrl: string; readonly apiKey: string },
  call: MachineApiCall
): Promise<unknown> => {
  const response = await fetchImpl(`${credentials.serverUrl.replace(/\/+$/, "")}${call.path}`, {
    method: call.method,
    headers: {
      "x-api-key": credentials.apiKey,
      ...(call.body === undefined ? {} : { "content-type": "application/json" })
    },
    ...(call.body === undefined ? {} : { body: JSON.stringify(call.body) })
  })
  const text = await response.text()
  if (!response.ok) throw new MachineApiError(response.status, text)
  return text === "" ? undefined : (JSON.parse(text) as unknown)
}

export class MachineApiError extends Error {
  constructor(
    readonly status: number,
    detail: string
  ) {
    super(`Cloud request failed (${status}): ${detail.slice(0, 200)}`)
  }
}
