import type { IncomingMessage, ServerResponse } from "node:http"

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
