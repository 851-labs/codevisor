import { emptyArguments, type EventType } from "@codevisor/plugin-kit"
import type { Tool } from "@modelcontextprotocol/sdk/types.js"

export const alertsIngress = "alerts"
export const alertFiringEvent = "alert.firing"
export const alertResolvedEvent = "alert.resolved"

const stringMap = { type: "object", additionalProperties: { type: "string" } }

const alertPayloadSchema = {
  type: "object",
  properties: {
    fingerprint: { type: "string" },
    status: { type: "string", enum: ["firing", "resolved"] },
    alertname: { type: "string" },
    labels: stringMap,
    annotations: stringMap,
    startsAt: { type: "string", format: "date-time" },
    endsAt: { type: "string", format: "date-time" },
    generatorURL: { type: "string" },
    values: { type: "object", additionalProperties: { type: "number" } }
  },
  required: [
    "fingerprint",
    "status",
    "alertname",
    "labels",
    "annotations",
    "startsAt",
    "endsAt",
    "generatorURL",
    "values"
  ]
}

export const grafanaEventTypes: ReadonlyArray<EventType> = [
  {
    name: alertFiringEvent,
    description: "A Grafana alert started firing.",
    delivery: ["push"],
    inputSchema: emptyArguments,
    payloadSchema: alertPayloadSchema
  },
  {
    name: alertResolvedEvent,
    description: "A firing Grafana alert resolved.",
    delivery: ["push"],
    inputSchema: emptyArguments,
    payloadSchema: alertPayloadSchema
  }
]

export const grafanaTools: ReadonlyArray<Tool> = [
  {
    name: "list_alerts",
    description: "List Grafana-managed alerts and their current state.",
    inputSchema: { type: "object", properties: {} }
  },
  {
    name: "get_alert_rule",
    description: "Get a Grafana alert rule by uid.",
    inputSchema: {
      type: "object",
      properties: { uid: { type: "string", description: "Alert rule uid." } },
      required: ["uid"]
    }
  },
  {
    name: "query",
    description: "Run one query against a Grafana datasource through the datasource query API.",
    inputSchema: {
      type: "object",
      properties: {
        datasourceUid: { type: "string" },
        query: {
          type: "object",
          description: 'Datasource-specific query fields, for example { "expr": "up" }.'
        },
        from: { type: "string", description: "Range start, for example now-1h." },
        to: { type: "string", description: "Range end, for example now." }
      },
      required: ["datasourceUid", "query"]
    }
  }
]
