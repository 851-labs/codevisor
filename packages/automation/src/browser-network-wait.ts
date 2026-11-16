import type { BrowserRuntime, PageHandle } from "./browser-cdp-engine.js"
import { delay } from "./browser-cdp.js"
import { tabSessionIds } from "./browser-frame-sessions.js"
import type { UrlMatcher } from "./browser-url-match.js"
import { optionalString, recordOrUndefined } from "./unknown-values.js"

export type NetworkEventKind = "request" | "response"

export interface NetworkWait {
  readonly kind: NetworkEventKind
  readonly matches: UrlMatcher
  readonly afterSequence: number
  readonly timeoutMs: number
}

export const waitForNetworkEvent = async (
  runtime: BrowserRuntime,
  page: PageHandle,
  wait: NetworkWait
): Promise<Readonly<Record<string, unknown>>> => {
  const deadline = Date.now() + wait.timeoutMs
  while (true) {
    const found = matchingEvent(runtime, page, wait)
    if (found !== undefined) return found
    if (Date.now() >= deadline) throw new Error(`Timed out waiting for a matching ${wait.kind}`)
    await delay(pollMs)
  }
}

export const responseBodyText = async (
  runtime: BrowserRuntime,
  page: PageHandle,
  requestId: string,
  sessionId: unknown
): Promise<string> => {
  const session = typeof sessionId === "string" ? sessionId : page.sessionId
  if (!tabSessionIds(runtime, page.sessionId).includes(session))
    throw new Error("That response belongs to another tab")

  const body = await runtime.connection
    .send<{ body: string; base64Encoded: boolean }>(
      "Network.getResponseBody",
      { requestId },
      session
    )
    .catch(() => {
      throw new Error(
        "The response body is no longer available; the browser keeps it only while the page that loaded it is open"
      )
    })
  return body.base64Encoded ? Buffer.from(body.body, "base64").toString("utf8") : body.body
}

type LoggedEvent = BrowserRuntime["eventLog"][number]

const pollMs = 50
const eventMethods = {
  request: "Network.requestWillBeSent",
  response: "Network.responseReceived"
} as const

const matchingEvent = (
  runtime: BrowserRuntime,
  page: PageHandle,
  wait: NetworkWait
): Readonly<Record<string, unknown>> | undefined => {
  const sessions = new Set(tabSessionIds(runtime, page.sessionId))
  const event = runtime.eventLog.find(
    (candidate) =>
      candidate.sequence > wait.afterSequence &&
      candidate.method === eventMethods[wait.kind] &&
      candidate.sessionId !== undefined &&
      sessions.has(candidate.sessionId) &&
      wait.matches(urlOf(candidate, wait.kind))
  )
  if (event === undefined) return undefined
  return wait.kind === "request" ? describeRequest(event) : describeResponse(runtime, event)
}

const urlOf = (event: LoggedEvent, kind: NetworkEventKind): string =>
  optionalString(recordOrUndefined(event.params[kind])?.url) ?? ""

const describeRequest = (event: LoggedEvent): Readonly<Record<string, unknown>> => {
  const request = recordOrUndefined(event.params.request) ?? {}
  return {
    sequence: event.sequence,
    sessionId: event.sessionId,
    requestId: event.params.requestId,
    url: request.url,
    method: request.method,
    requestHeaders: request.headers,
    postData: request.postData,
    resourceType: event.params.type
  }
}

const describeResponse = (
  runtime: BrowserRuntime,
  event: LoggedEvent
): Readonly<Record<string, unknown>> => {
  const response = recordOrUndefined(event.params.response) ?? {}
  const sent = runtime.eventLog.findLast(
    (candidate) =>
      candidate.method === eventMethods.request &&
      candidate.sessionId === event.sessionId &&
      candidate.params.requestId === event.params.requestId &&
      candidate.sequence < event.sequence
  )
  return {
    ...(sent === undefined ? {} : describeRequest(sent)),
    sequence: event.sequence,
    sessionId: event.sessionId,
    requestId: event.params.requestId,
    url: response.url,
    status: response.status,
    statusText: response.statusText,
    headers: response.headers,
    resourceType: event.params.type
  }
}
