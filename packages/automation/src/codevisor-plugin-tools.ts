import { Schema } from "effect"

import { localCallerId } from "./codevisor-agent-caller.js"
import { agentTool, type AgentTool, type AgentToolContext } from "./codevisor-agent-tool.js"

const SearchArgs = Schema.Struct({ query: Schema.optional(Schema.String) })
const DescribeArgs = Schema.Struct({ plugin: Schema.String })
const SetupArgs = Schema.Struct({ plugin: Schema.String, reason: Schema.String })

export const codevisorPluginTools: ReadonlyArray<AgentTool> = [
  agentTool(
    "plugins.search",
    "Search plugins (MCP servers with tools, events, skills and apps): installed ones and the ones Codevisor can install. Each item has plugin, name, description, installed, ready (installed, enabled and signed in), auth, accounts, and the names of its tools, events, skills and panes. Use it before telling the user something can't be done.",
    SearchArgs,
    (tool, args) => search(tool, Schema.decodeUnknownSync(SearchArgs)(args))
  ),
  agentTool(
    "plugins.describe",
    "Describe one plugin's real capabilities: tools with input schemas, events with payload schemas, skills, panes, and what signing in needs. Never claim a capability this doesn't list.",
    DescribeArgs,
    (tool, args) =>
      tool.api(
        "GET",
        `/v1/plugins/describe/${encodeURIComponent(Schema.decodeUnknownSync(DescribeArgs)(args).plugin)}`
      )
  ),
  agentTool(
    "plugins.request_setup",
    "Show the user a card in this chat to set up a plugin: install it, or just connect their account when it's installed but not signed in. reason is one plain sentence about what you'll do with it. Returns at once with outcome: ready (already set up, no card), requested (the card is showing; needs says install or connect), or disabled (installed but turned off, no card). It doesn't wait: after requested, end your turn, and a hidden <codevisor-event type=\"plugin.setup_finished\"> wakes you when the plugin is ready. Only call it after plugins.search and plugins.describe show the plugin can do what the user asked.",
    SetupArgs,
    (tool, args) => requestSetup(tool, Schema.decodeUnknownSync(SetupArgs)(args))
  )
]

const search = (tool: AgentToolContext, args: typeof SearchArgs.Type): Promise<unknown> =>
  tool.api("GET", "/v1/plugins/search", { query: { query: args.query } })

const requestSetup = (tool: AgentToolContext, args: typeof SetupArgs.Type): Promise<unknown> =>
  tool.api("POST", "/v1/plugins/setup-requests", {
    body: {
      sessionId: localCallerId(tool, "plugins.request_setup"),
      plugin: args.plugin,
      reason: args.reason
    }
  })
