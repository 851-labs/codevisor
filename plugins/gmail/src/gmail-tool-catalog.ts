import type { Tool } from "@modelcontextprotocol/sdk/types.js"

export const maxSearchResults = 25

const readOnly = { readOnlyHint: true, openWorldHint: false }
const writes = { readOnlyHint: false, destructiveHint: false, openWorldHint: false }
const relabels = { ...writes, idempotentHint: true }
const sends = { readOnlyHint: false, destructiveHint: false, openWorldHint: true }

const text = (description: string) => ({ type: "string", description })
const stringList = (description: string) => ({
  type: "array",
  items: { type: "string" },
  description
})

const searchInput: Tool["inputSchema"] = {
  type: "object",
  properties: {
    query: text("Gmail search syntax, for example from:alice is:unread newer_than:2d."),
    maxResults: {
      type: "integer",
      minimum: 1,
      maximum: maxSearchResults,
      description: "Defaults to 10."
    },
    pageToken: text("nextPageToken from a previous search.")
  },
  required: ["query"]
}

const recipients = {
  to: text("Comma-separated recipients, such as Ana <ana@example.com>, bo@example.com."),
  cc: text("Comma-separated recipients."),
  bcc: text("Comma-separated recipients."),
  subject: text("Subject line.")
}

const confirm = {
  type: "boolean",
  description:
    "Set true only after showing the user the exact recipients, subject and body and getting their explicit approval to send."
}

const targets = {
  messageIds: stringList("Gmail message ids."),
  threadIds: stringList("Gmail thread ids; changes every message in each thread.")
}

const labelTargets = (name: string, description: string): Tool => ({
  name,
  description,
  inputSchema: { type: "object", properties: targets },
  annotations: relabels
})

export const gmailTools: ReadonlyArray<Tool> = [
  {
    name: "search_messages",
    description: "Search messages. Returns compact summaries with message and thread ids.",
    inputSchema: searchInput,
    annotations: readOnly
  },
  {
    name: "search_threads",
    description: "Search conversations. Returns one compact summary per thread.",
    inputSchema: searchInput,
    annotations: readOnly
  },
  {
    name: "read_message",
    description:
      "Read one message: headers, labels, plain-text body and attachment names. The body includes quoted history.",
    inputSchema: {
      type: "object",
      properties: { messageId: text("Gmail message id.") },
      required: ["messageId"]
    },
    annotations: readOnly
  },
  {
    name: "read_thread",
    description:
      "Read a whole conversation, oldest first, with quoted history trimmed from each message.",
    inputSchema: {
      type: "object",
      properties: { threadId: text("Gmail thread id.") },
      required: ["threadId"]
    },
    annotations: readOnly
  },
  {
    name: "list_labels",
    description: "List the mailbox's labels with their ids and names.",
    inputSchema: { type: "object", properties: {} },
    annotations: readOnly
  },
  {
    name: "create_draft",
    description:
      "Create a draft without sending it. Pass inReplyToMessageId to draft a reply in that message's thread; recipients and subject then default to the reply's.",
    inputSchema: {
      type: "object",
      properties: {
        ...recipients,
        body: text("Plain-text body."),
        inReplyToMessageId: text("Gmail id of the message being answered."),
        replyAll: { type: "boolean", description: "With inReplyToMessageId, copy everyone." }
      },
      required: ["body"]
    },
    annotations: writes
  },
  {
    name: "update_draft",
    description: "Change a draft. Fields you leave out keep their current values.",
    inputSchema: {
      type: "object",
      properties: { draftId: text("Draft id."), ...recipients, body: text("Plain-text body.") },
      required: ["draftId"]
    },
    annotations: { ...writes, idempotentHint: true }
  },
  {
    name: "send",
    description:
      "Send a new message, or an existing draft by draftId. Requires the user's explicit approval: confirm must be true.",
    inputSchema: {
      type: "object",
      properties: {
        draftId: text("Send this draft instead of composing a new message."),
        ...recipients,
        body: text("Plain-text body."),
        confirm
      },
      required: ["confirm"]
    },
    annotations: sends
  },
  {
    name: "reply",
    description:
      "Send a reply in a message's thread, to its sender (or everyone with replyAll). Requires the user's explicit approval: confirm must be true.",
    inputSchema: {
      type: "object",
      properties: {
        messageId: text("Gmail id of the message being answered."),
        body: text("Plain-text body."),
        replyAll: { type: "boolean", description: "Copy everyone on the message." },
        cc: recipients.cc,
        confirm
      },
      required: ["messageId", "body", "confirm"]
    },
    annotations: sends
  },
  labelTargets("archive", "Archive messages or threads: remove them from the inbox."),
  {
    name: "modify_labels",
    description: "Add or remove labels by name or id on messages or threads.",
    inputSchema: {
      type: "object",
      properties: {
        ...targets,
        add: stringList("Label names or ids to add."),
        remove: stringList("Label names or ids to remove.")
      }
    },
    annotations: relabels
  },
  labelTargets("mark_read", "Mark messages or threads as read."),
  labelTargets("mark_unread", "Mark messages or threads as unread.")
]
