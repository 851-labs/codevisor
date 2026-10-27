import type { Server } from "@modelcontextprotocol/sdk/server/index.js"

import { unknownEventError } from "./plugin-protocol.js"
import { eventsListRequest } from "./plugin-requests.js"

export type DeliveryMode = "poll" | "push" | "webhook"

export interface EventType {
  name: string
  description: string
  delivery: ReadonlyArray<DeliveryMode>
  inputSchema: Record<string, unknown>
  payloadSchema: Record<string, unknown>
}

export const registerEventTypes = (server: Server, types: ReadonlyArray<EventType>): void => {
  server.setRequestHandler(eventsListRequest, () => ({ resultType: "complete", events: types }))
}

export const eventTypeNamed = (types: ReadonlyArray<EventType>, name: string): EventType => {
  const type = types.find((candidate) => candidate.name === name)
  if (type === undefined) throw unknownEventError(name)

  return type
}

export const emptyArguments = { type: "object", properties: {}, additionalProperties: true }
