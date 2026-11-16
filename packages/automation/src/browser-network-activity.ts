import { optionalString, recordOrUndefined } from "./unknown-values.js"

export const networkQuietMs = 500
export const longLivedRequestMs = 5_000

export interface NetworkActivity {
  readonly requests: Map<string, PendingRequest>
  changedAt: number
  latestUrl: string | undefined
}

export const newNetworkActivity = (now: number): NetworkActivity => ({
  requests: new Map(),
  changedAt: now,
  latestUrl: undefined
})

export const observeNetworkActivity = (
  activity: NetworkActivity,
  method: string,
  params: NetworkEventParams,
  now: number
): void => {
  observers[method]?.(activity, params, now)
}

export const networkIsQuiet = (activity: NetworkActivity, now: number): boolean =>
  now - activity.changedAt >= networkQuietMs && !loadingSomething(activity, now)

export const busyNetworkHint = (activity: NetworkActivity): string => {
  if (activity.latestUrl === undefined) return ""
  return `: the page is still making requests (latest ${activity.latestUrl}). Wait for the content you need with a locator instead`
}

type NetworkEventParams = Readonly<Record<string, unknown>>
type NetworkObserver = (activity: NetworkActivity, params: NetworkEventParams, now: number) => void

interface PendingRequest {
  readonly frameId: string | undefined
  readonly loaderId: string | undefined
  readonly startedAt: number
}

const backgroundRequestTypes = new Set(["WebSocket", "EventSource", "Ping"])
const eventStreamMimeType = "text/event-stream"
const latestUrlLength = 200

const isLongLived = (request: PendingRequest, now: number): boolean =>
  now - request.startedAt >= longLivedRequestMs

const loadingSomething = (activity: NetworkActivity, now: number): boolean =>
  [...activity.requests.values()].some((request) => !isLongLived(request, now))

const requestStarted: NetworkObserver = (activity, params, now) => {
  if (backgroundRequestTypes.has(String(params.type))) return

  activity.requests.set(String(params.requestId), {
    frameId: optionalString(params.frameId),
    loaderId: optionalString(params.loaderId),
    startedAt: now
  })
  activity.changedAt = now
  activity.latestUrl = optionalString(recordOrUndefined(params.request)?.url)?.slice(
    0,
    latestUrlLength
  )
}

const requestEnded: NetworkObserver = (activity, params, now) => {
  const requestId = String(params.requestId)
  const request = activity.requests.get(requestId)
  activity.requests.delete(requestId)
  if (request === undefined || !isLongLived(request, now)) activity.changedAt = now
}

const responseStarted: NetworkObserver = (activity, params) => {
  if (recordOrUndefined(params.response)?.mimeType !== eventStreamMimeType) return

  activity.requests.delete(String(params.requestId))
}

const frameLeft: NetworkObserver = (activity, params) => {
  for (const [requestId, request] of activity.requests)
    if (request.frameId === params.frameId) activity.requests.delete(requestId)
}

const documentReplaced: NetworkObserver = (activity, params) => {
  const frame = recordOrUndefined(params.frame)
  if (frame === undefined || frame.parentId !== undefined) return

  for (const [requestId, request] of activity.requests)
    if (request.loaderId !== frame.loaderId) activity.requests.delete(requestId)
}

const observers: Readonly<Record<string, NetworkObserver | undefined>> = {
  "Network.requestWillBeSent": requestStarted,
  "Network.loadingFinished": requestEnded,
  "Network.loadingFailed": requestEnded,
  "Network.responseReceived": responseStarted,
  "Page.frameDetached": frameLeft,
  "Page.frameNavigated": documentReplaced
}
