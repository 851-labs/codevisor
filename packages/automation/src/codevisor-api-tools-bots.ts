import {
  AddBotProjectRequest,
  CreateBotRequest,
  ForkBotRequest,
  UpdateBotRequest
} from "@codevisor/api"
import {
  botMascotColors,
  botMascotEyewear,
  botMascotHats,
  botMascotSwatches,
  type ItemOption
} from "@codevisor/bot-mascot"
import { Schema } from "effect"

import { apiTool, integerQuery, type CodevisorApiToolSpec } from "./codevisor-api-tool-spec.js"

export const BOT_TOOL_DEFAULTS = { symbolName: "sparkles" } as const

const MessageBotBody = Schema.Struct({ text: Schema.String })

const colorable = (items: ReadonlyArray<ItemOption<string>>): string =>
  items
    .filter((item) => item.swatches.length > 0)
    .map((item) => `${item.id} (${item.swatches.join(", ")})`)
    .join("; ")

const ItemColor = (part: string, items: ReadonlyArray<ItemOption<string>>) =>
  Schema.optional(
    Schema.Literals(["auto", ...botMascotSwatches.map((swatch) => swatch.id)])
  ).annotate({
    description: `The ${part}'s color. auto (the default) picks one to suit the body color. Only these take a color, from their own list: ${colorable(items)}.`
  })

const BotMascot = Schema.Struct({
  color: Schema.Literals(botMascotColors.map((color) => color.id)),
  hat: Schema.Literals(["none", ...botMascotHats.map((hat) => hat.id)]),
  hatColor: ItemColor("hat", botMascotHats),
  eyewear: Schema.Literals(["none", ...botMascotEyewear.map((eyewear) => eyewear.id)]),
  eyewearColor: ItemColor("eyewear", botMascotEyewear)
}).annotate({
  description:
    "The bot's avatar, a mascot with a body color, a hat and eyewear (none for neither), and colors for a hat or eyewear that offers them. A new bot gets the next color in turn and no hat or eyewear."
})

const ConfigSelections = Schema.Record(Schema.String, Schema.String).annotate({
  description:
    'Options for the bot\'s chat keyed by option id, such as { model: "…" } or { effort: "high" }. server.capabilities({ harnessId }) lists the harness\'s configOptions with their ids and values.'
})

const CreateBotBody = Schema.Struct({
  name: CreateBotRequest.fields.name,
  harnessId: CreateBotRequest.fields.harnessId.annotate({
    description: "The bot's harness, an id from harnesses.list(). It can't change later."
  }),
  projectIds: CreateBotRequest.fields.projectIds.annotate({
    description: "Projects from projects.list() to check out into the bot's folder. Can be empty."
  }),
  configSelections: Schema.optional(ConfigSelections),
  mascot: Schema.optional(BotMascot)
})

const ForkBotBody = Schema.Struct({
  harnessId: ForkBotRequest.fields.harnessId.annotate({
    description:
      "The fork's harness, an id from harnesses.list(). It can differ from the bot's own; that's the point of a fork."
  }),
  name: Schema.optional(
    Schema.String.annotate({
      description: "The fork's name. Defaults to the bot's name plus (fork)."
    })
  ),
  configSelections: Schema.optional(ConfigSelections),
  mascot: Schema.optional(
    BotMascot.annotate({ description: "The fork's avatar. Defaults to the bot's own mascot." })
  ),
  moveAgents: Schema.optional(
    Schema.Boolean.annotate({
      description:
        "true (the default) transfers every agent the bot started to the fork, so their results go to it. false leaves them with the bot."
    })
  )
})

const UpdateBotBody = Schema.Struct({
  name: UpdateBotRequest.fields.name,
  configSelections: Schema.optional(ConfigSelections),
  mascot: Schema.optional(BotMascot),
  isArchived: Schema.optional(
    Schema.Boolean.annotate({
      description: "true archives the bot: it stops and moves to Archived. false restores it."
    })
  )
})

export const codevisorBotApiTools: ReadonlyArray<CodevisorApiToolSpec> = [
  apiTool(
    "bots.list",
    "List this machine's Codevisor bots, archived ones included: botId, name, mascot, harnessId, configSelections (the options picked for its chat, such as its model; absent while it uses the harness defaults), isArchived, projects (each checked-out repository), rootPath (the bot's folder) and agentId (the bot's own chat, for agents.status).",
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
    "Change a bot's name, mascot or chat options such as its model, or archive (isArchived: true) and restore it. Pass only what changes. Returns the bot.",
    "PATCH",
    "/v1/bots/:id",
    { body: UpdateBotBody }
  ),
  apiTool(
    "bots.fork",
    "Fork a bot onto another harness or model, the same as Fork… in the app. The fork gets the bot's projects, mascot, notes and conversation, and on its first turn a summary of where things stand. Returns the new bot.",
    "POST",
    "/v1/bots/:id/fork",
    { body: ForkBotBody }
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
    "Remove a project from a bot and delete its checkout. Returns the bot.",
    "DELETE",
    "/v1/bots/:id/projects/:projectId"
  ),
  apiTool(
    "bots.message",
    'Send a message to a bot, from you: another bot, or an agent. For a bot on another machine pass machine. It lands in your thread with that bot, which the user is not part of, and the bot reads it at its next step. Its reply reaches you as a <codevisor-event type="thread.message">. A bot refuses this from an agent it started, whose final reply it already gets. Returns { sent, threadId, messageId }.',
    "POST",
    "/v1/bots/:id/messages",
    { body: MessageBotBody }
  ),
  apiTool(
    "bots.messages",
    "Read your thread with a bot, oldest first: { threadId?, items: [{ from, mine, text, sentAt }], next? }. Pass next back as before for older ones.",
    "GET",
    "/v1/bots/:id/messages",
    {
      query: [
        integerQuery(
          "limit",
          "How many messages to return, newest last. Defaults to 10, at most 50."
        ),
        integerQuery(
          "before",
          "The next value from the previous call, to page back to older messages."
        )
      ]
    }
  ),
  apiTool(
    "bots.delete",
    "Delete a bot for good: its chat, its agents' workspaces and its folder. Use bots.update({ isArchived: true }) to keep it restorable. Confirm with the user first.",
    "DELETE",
    "/v1/bots/:id",
    { confirm: true }
  )
]
