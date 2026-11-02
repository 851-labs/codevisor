import { AddBotProjectRequest, BotMode, CreateBotRequest, UpdateBotRequest } from "@codevisor/api"
import { Schema } from "effect"

import { apiTool, type CodevisorApiToolSpec } from "./codevisor-api-tool-spec.js"

const BOT_SYMBOL_NAMES = [
  "sparkles",
  "brain",
  "wand.and.stars",
  "hammer",
  "wrench.and.screwdriver",
  "ant",
  "ladybug",
  "shield.lefthalf.filled",
  "magnifyingglass",
  "doc.text",
  "book",
  "paintbrush",
  "chart.line.uptrend.xyaxis",
  "bolt",
  "flame",
  "leaf",
  "paperplane",
  "bell",
  "star",
  "cpu"
] as const

export const BOT_TOOL_DEFAULTS = { symbolName: "sparkles", mode: "conversation" } as const

const BotSymbolName = Schema.Literals(BOT_SYMBOL_NAMES).annotate({
  description: "The bot's icon, an SF Symbol name. Defaults to sparkles."
})

const ConfigSelections = Schema.Record(Schema.String, Schema.String).annotate({
  description:
    'Options for the bot\'s chat keyed by option id, such as { model: "…" } or { effort: "high" }. server.capabilities({ harnessId }) lists the harness\'s configOptions with their ids and values.'
})

const BotModeChoice = BotMode.annotate({
  description:
    "How the user sees the bot. conversation (the default): like a messaging app, showing only the messages the bot sends with messages.send. transcript: everything the bot does, tool calls included, like any other chat. bubbles: the bot's replies as message bubbles, tool calls hidden."
})

const CreateBotBody = Schema.Struct({
  name: CreateBotRequest.fields.name,
  harnessId: CreateBotRequest.fields.harnessId.annotate({
    description: "The bot's harness, an id from harnesses.list(). It can't change later."
  }),
  projectIds: CreateBotRequest.fields.projectIds.annotate({
    description: "Projects from projects.list() to check out into the bot's folder. At least one."
  }),
  configSelections: Schema.optional(ConfigSelections),
  symbolName: Schema.optional(BotSymbolName),
  mode: Schema.optional(BotModeChoice)
})

const UpdateBotBody = Schema.Struct({
  name: UpdateBotRequest.fields.name,
  configSelections: Schema.optional(ConfigSelections),
  symbolName: Schema.optional(BotSymbolName),
  mode: Schema.optional(BotModeChoice),
  isArchived: Schema.optional(
    Schema.Boolean.annotate({
      description: "true archives the bot: it stops and moves to Archived. false restores it."
    })
  )
})

export const codevisorBotApiTools: ReadonlyArray<CodevisorApiToolSpec> = [
  apiTool(
    "bots.list",
    "List this machine's Codevisor bots, archived ones included: botId, name, symbolName, harnessId, mode, isArchived, projects (each checked-out repository), rootPath (the bot's folder) and agentId (the bot's own chat, for agents.status or agents.message).",
    "GET",
    "/v1/bots"
  ),
  apiTool("bots.get", "Read one bot, with the same fields as bots.list.", "GET", "/v1/bots/:id"),
  apiTool(
    "bots.create",
    "Create a bot on this machine, the same as New Bot in the app: it shows up in the user's sidebar on every device. Codevisor checks each project out into the bot's own folder and starts its chat. Returns the bot.",
    "POST",
    "/v1/bots",
    { body: CreateBotBody }
  ),
  apiTool(
    "bots.update",
    "Change a bot's name, icon, mode or chat options such as its model, or archive (isArchived: true) and restore it. Pass only what changes. Returns the bot.",
    "PATCH",
    "/v1/bots/:id",
    { body: UpdateBotBody }
  ),
  apiTool(
    "bots.projects_add",
    "Add a project to a bot and check its repository out into the bot's folder. Get projectIds from projects.list(). Returns the bot.",
    "POST",
    "/v1/bots/:id/projects",
    { body: AddBotProjectRequest }
  ),
  apiTool(
    "bots.projects_remove",
    "Remove a project from a bot and delete its checkout. A bot keeps at least one project. Returns the bot.",
    "DELETE",
    "/v1/bots/:id/projects/:projectId"
  ),
  apiTool(
    "bots.delete",
    "Delete a bot for good: its chat, its agents' workspaces and its folder. Use bots.update({ isArchived: true }) to keep it restorable. Confirm with the user first.",
    "DELETE",
    "/v1/bots/:id",
    { confirm: true }
  )
]
