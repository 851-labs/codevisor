import type { HubInboxItem, InboxOAuthResult } from "@codevisor/api"
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
  readonly state: string
  readonly code?: string
  readonly issuer?: string
  readonly error?: string
}

export type InboxOAuthOutcome =
  | { readonly ok: true }
  | { readonly ok: false; readonly error: string }

export type InboxOAuthHandler = (callback: InboxOAuthCallback) => Promise<InboxOAuthOutcome>

export interface InboxReceipt {
  readonly oauth?: InboxOAuthOutcome
}

export interface CloudInbox {
  readonly receive: (secretKey: string, frame: HubInboxItem) => Promise<InboxReceipt>
  readonly onWebhook: (handler: (request: InboxWebhookRequest) => Promise<void>) => () => void
  readonly onOAuth: (handler: InboxOAuthHandler) => () => void
}

export const makeCloudInbox = (): CloudInbox => {
  const webhookHandlers = new Set<(request: InboxWebhookRequest) => Promise<void>>()
  const oauthHandlers = new Set<InboxOAuthHandler>()
  const seen = new Set<string>()

  const dispatch = async (frame: HubInboxItem, payload: unknown): Promise<InboxReceipt> => {
    if (frame.kind === "oauth") return { oauth: await finishOAuth(oauthHandlers, payload) }

    const request = webhookRequestOf(payload)
    if (request !== undefined) await all(webhookHandlers, request)
    return {}
  }

  return {
    receive: async (secretKey, frame) => {
      if (seen.has(frame.itemId)) return {}
      const receipt = await dispatch(frame, openInboxItem(secretKey, frame))
      remember(seen, frame.itemId)
      return receipt
    },
    onWebhook: (handler) => register(webhookHandlers, handler),
    onOAuth: (handler) => register(oauthHandlers, handler)
  }
}

export type InboxAck = (
  itemIds: ReadonlyArray<string>,
  results: ReadonlyArray<InboxOAuthResult>
) => void

export const inboxFrameHandler =
  (inbox: CloudInbox, secretKey: string, ack: InboxAck) =>
  (frame: HubInboxItem): void => {
    void inbox.receive(secretKey, frame).then(
      (receipt) => ack([frame.itemId], oauthResults(frame.itemId, receipt)),
      () => undefined
    )
  }

const oauthResults = (itemId: string, receipt: InboxReceipt): ReadonlyArray<InboxOAuthResult> =>
  receipt.oauth === undefined ? [] : [{ itemId, ...receipt.oauth }]

const unclaimedSignIn: InboxOAuthOutcome = {
  ok: false,
  error: "No sign-in on this machine was waiting for it"
}

const finishOAuth = async (
  handlers: ReadonlySet<InboxOAuthHandler>,
  payload: unknown
): Promise<InboxOAuthOutcome> => {
  const callback = oauthCallbackOf(payload)
  if (callback === undefined) return { ok: false, error: "The sign-in callback was malformed" }

  const outcomes = await Promise.all([...handlers].map((handler) => handler(callback)))
  return outcomes.find((outcome) => !outcome.ok) ?? outcomes[0] ?? unclaimedSignIn
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
  if (!isRecord(payload) || !isString(payload.state)) return undefined
  return {
    state: payload.state,
    ...(isString(payload.code) ? { code: payload.code } : {}),
    ...(isString(payload.iss) ? { issuer: payload.iss } : {}),
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
