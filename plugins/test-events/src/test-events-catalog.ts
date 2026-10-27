import { emptyArguments, type EventType } from "@codevisor/plugin-kit"
import type { Tool } from "@modelcontextprotocol/sdk/types.js"

export const eventsPageUri = "ui://test-events/events.html"

export const pingEvent = "test.ping"
export const counterEvent = "test.counter"

export const testEventTypes: ReadonlyArray<EventType> = [
  {
    name: pingEvent,
    description: "A test ping published by the emit tool.",
    delivery: ["poll", "push"],
    inputSchema: emptyArguments,
    payloadSchema: {
      type: "object",
      properties: {
        message: { type: "string" },
        level: { type: "string", enum: ["info", "warn", "error"] },
        tags: { type: "array", items: { type: "string" } },
        count: { type: "integer" }
      },
      required: ["message", "level", "tags", "count"]
    }
  },
  {
    name: counterEvent,
    description: "A counter tick, published by the emit tool or the optional interval timer.",
    delivery: ["poll", "push"],
    inputSchema: emptyArguments,
    payloadSchema: {
      type: "object",
      properties: { value: { type: "integer" } },
      required: ["value"]
    }
  }
]

const limitProperty = {
  type: "integer",
  minimum: 1,
  maximum: 200,
  description: "How many recent events to return."
}

export const testEventTools: ReadonlyArray<Tool> = [
  {
    name: "emit",
    description: "Publish a test event to every open stream and to the poll buffer.",
    inputSchema: {
      type: "object",
      properties: {
        name: { type: "string", enum: testEventTypes.map((type) => type.name) },
        data: { type: "object", description: "Payload fields; missing fields get defaults." },
        eventId: { type: "string", description: "Stable event id; generated when omitted." }
      },
      required: ["name"]
    }
  },
  {
    name: "list_recent",
    description: "List the most recent test events, oldest first.",
    inputSchema: { type: "object", properties: { limit: limitProperty } }
  },
  {
    name: "show_events",
    description: "Show the most recent test events in an interactive view.",
    inputSchema: { type: "object", properties: { limit: limitProperty } },
    _meta: { ui: { resourceUri: eventsPageUri } }
  }
]

export const pingDefaults = { message: "ping", level: "info", tags: [], count: 1 }
