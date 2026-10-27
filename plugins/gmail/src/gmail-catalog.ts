import { emptyArguments, type EventType } from "@codevisor/plugin-kit"
import type { Tool } from "@modelcontextprotocol/sdk/types.js"

export const messageReceivedEvent = "message.received"

const stringList = { type: "array", items: { type: "string" } }

export const gmailEventTypes: ReadonlyArray<EventType> = [
  {
    name: messageReceivedEvent,
    description: "A new message arrived in the inbox. Mail you sent yourself is skipped.",
    delivery: ["poll"],
    inputSchema: emptyArguments,
    payloadSchema: {
      type: "object",
      properties: {
        messageId: { type: "string" },
        threadId: { type: "string" },
        from: {
          type: "object",
          properties: { email: { type: "string" }, name: { type: "string" } },
          required: ["email", "name"]
        },
        to: stringList,
        cc: stringList,
        subject: { type: "string" },
        snippet: { type: "string" },
        labels: stringList,
        receivedAt: { type: "string", format: "date-time" }
      },
      required: [
        "messageId",
        "threadId",
        "from",
        "to",
        "cc",
        "subject",
        "snippet",
        "labels",
        "receivedAt"
      ]
    }
  }
]

const readOnly = { readOnlyHint: true, openWorldHint: false }

const replyProperties = {
  threadId: { type: "string", description: "Thread to add the message to." },
  inReplyToMessageId: {
    type: "string",
    description:
      "Gmail id of the message being answered; sets In-Reply-To, References and the thread."
  }
}

export const gmailTools: ReadonlyArray<Tool> = [
  {
    name: "search",
    description:
      "Search messages with Gmail query syntax, for example from:alice is:unread newer_than:2d.",
    inputSchema: {
      type: "object",
      properties: {
        query: { type: "string" },
        maxResults: { type: "integer", minimum: 1, maximum: 50, description: "Defaults to 10." }
      },
      required: ["query"]
    },
    annotations: readOnly
  },
  {
    name: "read_message",
    description: "Read one message: headers, labels, snippet and the plain-text body.",
    inputSchema: {
      type: "object",
      properties: { messageId: { type: "string" } },
      required: ["messageId"]
    },
    annotations: readOnly
  },
  {
    name: "read_thread",
    description: "Read every message in a thread, oldest first.",
    inputSchema: {
      type: "object",
      properties: { threadId: { type: "string" } },
      required: ["threadId"]
    },
    annotations: readOnly
  },
  {
    name: "create_draft",
    description: "Create a draft. When replying, To defaults to the original sender.",
    inputSchema: {
      type: "object",
      properties: {
        to: { type: "string", description: "Comma-separated recipients." },
        subject: { type: "string" },
        body: { type: "string", description: "Plain-text body." },
        ...replyProperties
      },
      required: ["body"]
    },
    annotations: { readOnlyHint: false, destructiveHint: false, openWorldHint: false }
  },
  {
    name: "send",
    description:
      "Send a message now. Prefer create_draft when the recipients or wording are uncertain.",
    inputSchema: {
      type: "object",
      properties: {
        to: { type: "string", description: "Comma-separated recipients." },
        cc: { type: "string", description: "Comma-separated recipients." },
        subject: { type: "string" },
        body: { type: "string", description: "Plain-text body." },
        ...replyProperties
      },
      required: ["to", "subject", "body"]
    },
    annotations: { readOnlyHint: false, destructiveHint: false, openWorldHint: true }
  },
  {
    name: "modify_labels",
    description:
      "Add or remove label ids on a message, for example remove UNREAD to mark it read or INBOX to archive.",
    inputSchema: {
      type: "object",
      properties: {
        messageId: { type: "string" },
        add: stringList,
        remove: stringList
      },
      required: ["messageId"]
    },
    annotations: {
      readOnlyHint: false,
      destructiveHint: false,
      idempotentHint: true,
      openWorldHint: false
    }
  }
]
