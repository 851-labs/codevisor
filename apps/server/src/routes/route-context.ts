import type { IncomingMessage, ServerResponse } from "node:http"

import { matchRoute, matchRouteParams } from "../server-context.js"
import type {
  CodevisorServerConfig,
  CodevisorServerServices,
  EventFanout,
  RouteState
} from "../server-context.js"

export interface RouteContext {
  readonly services: CodevisorServerServices
  readonly fanout: EventFanout
  readonly routeState: RouteState
  readonly request: IncomingMessage
  readonly response: ServerResponse
  readonly url: URL
  readonly config: CodevisorServerConfig
}

export const rejectSyncThrows = (dispatch: () => Promise<boolean>): Promise<boolean> => {
  try {
    return dispatch()
  } catch (cause) {
    return Promise.reject(cause)
  }
}

export const isRoute = (
  url: URL,
  request: IncomingMessage,
  pathname: string,
  method: string
): boolean => url.pathname === pathname && request.method === method

export const whenMethod = <T>(
  request: IncomingMessage,
  method: string,
  match: T | undefined
): T | undefined => {
  if (match === undefined) return undefined
  if (request.method !== method) return undefined
  return match
}

export const methodRouteId = (
  { request, url }: RouteContext,
  method: string,
  pattern: string
): string | undefined => whenMethod(request, method, matchRoute(url.pathname, pattern))

export const methodRouteParams = (
  { request, url }: RouteContext,
  method: string,
  pattern: string
): Record<string, string> | undefined =>
  whenMethod(request, method, matchRouteParams(url.pathname, pattern))
