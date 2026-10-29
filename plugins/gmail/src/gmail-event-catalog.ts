import { emptyArguments, type EventType } from "@codevisor/plugin-kit"

export const messageReceivedEvent = "message.received"

export const gmailIngress = { name: "gmail", title: "Gmail push notifications", route: "gmail" }

const stringList = { type: "array", items: { type: "string" } }

export const gmailEventTypes: ReadonlyArray<EventType> = [
  {
    name: messageReceivedEvent,
    description: "A new message arrived in the inbox. Mail you sent yourself is skipped.",
    delivery: ["push"],
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
