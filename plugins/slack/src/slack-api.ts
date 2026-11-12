import { rejectedSlackToken } from "./slack-account.js"

export type Fetch = (url: string, init: RequestInit) => Promise<Response>

export type SlackParams = Readonly<Record<string, unknown>>

export interface SlackReply {
  body: Record<string, unknown>
  scopes: ReadonlyArray<string>
}

export interface SlackApi {
  call(method: string, params?: SlackParams): Promise<Record<string, unknown>>
  callWithScopes(method: string, params?: SlackParams): Promise<SlackReply>
  fetchFile(url: string): Promise<Uint8Array<ArrayBuffer>>
  sendFile(url: string, bytes: Uint8Array<ArrayBuffer>): Promise<void>
}

export class SlackApiError extends Error {
  constructor(
    readonly code: string,
    message: string
  ) {
    super(message)
  }
}

export const slackApiUrl = "https://slack.com/api/"

export const rejectsToken = (error: SlackApiError): boolean => signInErrors.has(error.code)

export const slackApi = (fetcher: Fetch, token: string): SlackApi => {
  const authorization = `Bearer ${token}`

  const reply = async (method: string, params: SlackParams = {}): Promise<SlackReply> => {
    const response = await fetcher(`${slackApiUrl}${method}`, {
      method: "POST",
      headers: { authorization, "content-type": "application/x-www-form-urlencoded" },
      body: formOf(params)
    })
    return { body: await bodyOf(response, method), scopes: scopesOf(response) }
  }

  return {
    call: async (method, params) => (await reply(method, params)).body,
    callWithScopes: reply,
    fetchFile: async (url) => {
      const response = await fetcher(url, { headers: { authorization } })
      if (!response.ok) throw transferFailed("send", response)

      return new Uint8Array(await response.arrayBuffer())
    },
    sendFile: async (url, bytes) => {
      const response = await fetcher(url, { method: "POST", body: bytes })
      if (!response.ok) throw transferFailed("take", response)
    }
  }
}

const formOf = (params: SlackParams): string =>
  new URLSearchParams(
    Object.entries(params).flatMap(([key, value]) =>
      value === undefined ? [] : [[key, formValue(value)]]
    )
  ).toString()

const formValue = (value: unknown): string =>
  typeof value === "object" && value !== null ? JSON.stringify(value) : String(value)

const bodyOf = async (response: Response, method: string): Promise<Record<string, unknown>> => {
  if (response.status === tooManyRequests) throw rateLimited(response)

  const body: unknown = await response.json().catch(() => undefined)
  if (!isRecord(body))
    throw new SlackApiError(
      "invalid_response",
      `Slack sent an unreadable reply to ${method} (HTTP ${response.status}).`
    )
  if (body.ok !== true) throw slackError(body)

  return body
}

const tooManyRequests = 429

const rateLimited = (response: Response): SlackApiError => {
  const seconds = response.headers.get("retry-after") ?? "a few"
  return new SlackApiError(
    "ratelimited",
    `Slack is rate limiting these requests. Try again in ${seconds} seconds.`
  )
}

const scopesOf = (response: Response): ReadonlyArray<string> =>
  (response.headers.get("x-oauth-scopes") ?? "")
    .split(",")
    .map((scope) => scope.trim())
    .filter((scope) => scope !== "")

const slackError = (body: Record<string, unknown>): SlackApiError => {
  const code = typeof body.error === "string" ? body.error : "unknown_error"
  return new SlackApiError(code, errorMessage(code, body))
}

const errorMessage = (code: string, body: Record<string, unknown>): string => {
  if (signInErrors.has(code)) return rejectedSlackToken
  if (code === "missing_scope") return missingScope(body.needed)

  return knownErrors[code] ?? `Slack returned ${code}.`
}

const signInErrors = new Set([
  "invalid_auth",
  "not_authed",
  "token_revoked",
  "token_expired",
  "account_inactive"
])

const missingScope = (needed: unknown): string =>
  `The Slack app is missing the ${typeof needed === "string" ? needed : "needed"} permission. Add it under OAuth & Permissions › User Token Scopes, then reinstall the app.`

const knownErrors: Readonly<Record<string, string>> = {
  channel_not_found: "Slack couldn't find that conversation, or you aren't in it.",
  not_in_channel: "You aren't a member of that channel.",
  is_archived: "That channel is archived.",
  message_not_found: "Slack couldn't find that message.",
  thread_not_found: "Slack couldn't find that thread.",
  already_reacted: "You already reacted with that emoji.",
  no_reaction: "You haven't reacted with that emoji.",
  invalid_name: "Slack doesn't have an emoji with that name.",
  users_not_found: "Slack couldn't find that person.",
  user_not_found: "Slack couldn't find that person.",
  file_not_found: "Slack couldn't find that file.",
  time_in_past: "postAt must be in the future.",
  time_too_far: "Slack can only schedule messages up to 120 days ahead.",
  msg_too_long: "That message is too long for Slack."
}

const transferFailed = (verb: "send" | "take", response: Response): SlackApiError =>
  new SlackApiError(
    "file_transfer_failed",
    `Slack didn't ${verb} the file (HTTP ${response.status}).`
  )

const isRecord = (value: unknown): value is Record<string, unknown> =>
  typeof value === "object" && value !== null && !Array.isArray(value)
