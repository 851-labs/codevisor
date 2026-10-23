import { AddBotProjectRequest, SendBotMessageRequest, TerminalCreateRequest } from "@codevisor/api"

import { stringQuery, apiTool, type CodevisorApiToolSpec } from "./codevisor-api-tool-spec.js"

export const codevisorSessionApiTools: ReadonlyArray<CodevisorApiToolSpec> = [
  apiTool(
    "messages.send",
    "Send a chat message to the user. As a Codevisor bot this is the only way the user sees anything you write. text is markdown (bold, italics, inline code, links, lists, code blocks); attachments are absolute paths of files on this machine to send with it.",
    "POST",
    "/v1/sessions/:id/messages",
    { body: SendBotMessageRequest }
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
    "Remove a project from this bot and delete its checkout from the bot's folder. A bot keeps at least one project. Returns the bot with its remaining projects.",
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
