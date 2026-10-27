import type { EventFilterContext } from "./event-filter-variables.js"

export const grafanaAlertSchema = {
  type: "object",
  properties: {
    status: { type: "string", enum: ["firing", "resolved"] },
    severity: { type: "string" },
    labels: { type: "object", additionalProperties: { type: "string" } },
    annotations: { type: "object", additionalProperties: { type: "string" } },
    values: { type: "object", additionalProperties: { type: "number" } },
    startsAt: { type: "string", format: "date-time" },
    endsAt: { type: ["string", "null"], format: "date-time" },
    fingerprint: { type: "string" },
    silenceCount: { type: "integer" }
  }
}

export const firingAlert = {
  status: "firing",
  severity: "critical",
  labels: { alertname: "HighCPU", host: "db-1", team: "storage" },
  annotations: { summary: "Disk almost full on db-1" },
  values: { cpu: 0.95 },
  startsAt: "2026-10-27T10:00:00Z",
  endsAt: null,
  fingerprint: "a1b2c3",
  silenceCount: 0
}

export const gmailMessageSchema = {
  type: "object",
  properties: {
    messageId: { type: "string" },
    threadId: { type: "string" },
    from: { type: "object", properties: { email: { type: "string" }, name: { type: "string" } } },
    to: { type: "array", items: { type: "string" } },
    subject: { type: "string" },
    snippet: { type: "string" },
    labels: { type: "array", items: { type: "string" } },
    sizeEstimate: { type: "integer" },
    hasAttachments: { type: "boolean" },
    attachments: {
      type: "array",
      items: {
        type: "object",
        properties: { filename: { type: "string" }, size: { type: "integer" } }
      }
    }
  }
}

export const invoiceMessage = {
  messageId: "18c0f",
  threadId: "18c0e",
  from: { email: "pat@client.com", name: "Pat" },
  to: ["me@example.com", "billing@example.com"],
  subject: "Invoice 42 for October",
  snippet: "Please find attached",
  labels: ["INBOX", "UNREAD"],
  sizeEstimate: 48213,
  hasAttachments: true,
  attachments: [{ filename: "invoice-42.pdf", size: 2048 }]
}

export const alertContext: EventFilterContext = {
  eventId: "a1b2c3:2026-10-27T10:00:00Z",
  name: "alert.firing",
  timestamp: "2026-10-27T10:00:00Z",
  account: { id: "acct-1", label: "Work", identity: "ops@example.com" }
}

export const messageContext: EventFilterContext = {
  eventId: "18c0f",
  name: "message.received",
  timestamp: "2026-10-27T09:30:00Z"
}
