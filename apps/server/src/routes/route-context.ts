import type { IncomingMessage, ServerResponse } from "node:http"

import { matchRoute, matchRouteParams, writeFailure } from "../server-context.js"
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

export type RouteHandler = (route: RouteContext) => void | Promise<void>

export type RouteFamily = (route: RouteContext) => Promise<boolean>

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

export const isMethodRoute = (
  request: IncomingMessage,
  url: URL,
  method: string,
  pathname: string
): boolean => request.method === method && url.pathname === pathname

export const respondAfter = async <T>(
  response: ServerResponse,
  pending: Promise<T>,
  write: (value: T) => void | Promise<void> = ignoreResult
): Promise<void> => {
  try {
    return write(await pending)
  } catch (cause) {
    writeFailure(response, cause)
  }
}

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

const ignoreResult = (): void => undefined
