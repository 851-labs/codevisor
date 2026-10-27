import { Schema } from "effect"

import { localCallerId } from "./codevisor-agent-caller.js"
import { agentTool, type AgentTool, type AgentToolContext } from "./codevisor-agent-tool.js"

const SearchArgs = Schema.Struct({ query: Schema.optional(Schema.String) })
const DescribeArgs = Schema.Struct({ plugin: Schema.String })
const SetupArgs = Schema.Struct({ plugin: Schema.String, reason: Schema.String })

export const setupWaitMarginMs = 5_000
export const maxSetupWaitMs = 5 * 60_000

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
    "Ask the user to install a plugin and sign in, from a card in this chat that works on any of their devices. reason is one plain sentence about what you'll do with it. Waits while the user sets it up and returns outcome: connected (ready to use), declined, or pending (the card stays; call again to keep waiting). Only call it after plugins.search and plugins.describe show the plugin can do what the user asked.",
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
      reason: args.reason,
      waitMs: setupWaitMs(tool.context.deadline)
    }
  })

export const setupWaitMs = (deadline: number | undefined): number =>
  Math.max(
    0,
    Math.min(maxSetupWaitMs, (deadline ?? Infinity) - setupWaitMarginMs - performance.now())
  )
