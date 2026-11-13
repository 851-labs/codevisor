import { AddBotProjectRequest, SendBotMessageRequest, TerminalCreateRequest } from "@codevisor/api"

import {
  apiTool,
  integerQuery,
  stringQuery,
  type CodevisorApiToolSpec,
  type QueryParameter
} from "./codevisor-api-tool-spec.js"

const senderQuery: QueryParameter = {
  name: "sender",
  schema: { type: "string", enum: ["user", "bot", "notice"] },
  description:
    "Only messages from this sender: user (the user), bot (what you sent with messages.send), or notice (Codevisor's notices in the chat). Leave it out for all of them."
}

export const codevisorSessionApiTools: ReadonlyArray<CodevisorApiToolSpec> = [
  apiTool(
    "messages.send",
    "Send a chat message to the user. As a Codevisor bot this is the only way the user sees anything you write. text is markdown (bold, italics, inline code, links, lists, code blocks); attachments are absolute paths of files on this machine to send with it. Pass threadId to reply in a thread with another bot or an agent instead: the user is not in a thread, and a thread message takes no attachments.",
    "POST",
    "/v1/sessions/:id/messages",
    { body: SendBotMessageRequest }
  ),
  apiTool(
    "messages.list",
    "Read the latest messages in your chat with the user, oldest first: what they wrote, what you sent, and Codevisor's notices. Use it when a reply such as \"go for it\" depends on something you said that you can't see. Returns { items: [{ sender, text, attachments?, sentAt }], next? }; pass next back as before for older ones. Pass threadId to read a thread with another bot or an agent instead: { items: [{ from, mine, text, sentAt }], next? }.",
    "GET",
    "/v1/sessions/:id/messages",
    {
      query: [
        integerQuery(
          "limit",
          "How many messages to return, newest last. Defaults to 10, at most 50."
        ),
        senderQuery,
        integerQuery(
          "before",
          "The next value from the previous call, to page back to older messages."
        ),
        stringQuery("threadId", "Read this thread instead of your chat with the user.")
      ]
    }
  ),
  apiTool(
    "messages.threads",
    "List your threads with other bots and with agents, most recently active first: { items: [{ threadId, with: { kind, name, botId?, agentId }, lastMessage?: { from, mine, text, sentAt } }] }. The user is not in a thread.",
    "GET",
    "/v1/sessions/:id/threads"
  ),
  apiTool(
    "bot.projects_add",
    "Add a Codevisor project to this bot when a task needs a repository it doesn't have. Codevisor checks the repository out read-only into the bot's folder and lists it in AGENTS.md. Get projectIds from projects.list. Returns the bot with all its projects.",
    "POST",
    "/v1/sessions/:id/bot/projects",
    { body: AddBotProjectRequest }
  ),
  apiTool(
    "bot.projects_remove",
    "Remove a project from this bot and delete its checkout from the bot's folder. Returns the bot with its remaining projects.",
    "DELETE",
    "/v1/sessions/:id/bot/projects/:projectId"
  ),
  apiTool(
    "terminals.create",
    "Create or reattach a server-side terminal.",
    "POST",
    "/v1/terminals",
    {
      body: TerminalCreateRequest
    }
  ),
  apiTool(
    "terminals.close_session",
    "Close the live terminal associated with a session key.",
    "DELETE",
    "/v1/terminals/session/:sessionId"
  ),
  apiTool(
    "files.upload",
    "Upload a base64-encoded file to Codevisor for prompt attachments.",
    "POST",
    "/v1/files",
    {
      query: [stringQuery("name"), stringQuery("mimeType")]
    }
  ),
  apiTool(
    "files.download",
    "Download a Codevisor attachment as an MCP binary resource.",
    "GET",
    "/v1/files/:id",
    {
      response: "binary"
    }
  )
]
