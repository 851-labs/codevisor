import { PluginEventSubscription, PluginEventType } from "@codevisor/api"
import { Schema } from "effect"

import { localCallerId } from "./codevisor-agent-caller.js"
import { agentTool, type AgentTool, type AgentToolContext } from "./codevisor-agent-tool.js"

const TopicsArgs = Schema.Struct({ query: Schema.optional(Schema.String) })
const SubscribeArgs = Schema.Struct({
  plugin: Schema.String,
  event: Schema.String,
  filter: Schema.optional(Schema.String),
  arguments: Schema.optional(Schema.Record(Schema.String, Schema.Unknown)),
  account: Schema.optional(Schema.String),
  note: Schema.String,
  once: Schema.optional(Schema.Boolean)
})
const PreviewArgs = Schema.Struct({
  plugin: Schema.String,
  event: Schema.String,
  filter: Schema.optional(Schema.String),
  account: Schema.optional(Schema.String)
})
const SubscriptionIdArgs = Schema.Struct({ subscriptionId: Schema.String })
const EventIdArgs = Schema.Struct({ eventId: Schema.String })
const NoArgs = Schema.Struct({})

export const codevisorEventTools: ReadonlyArray<AgentTool> = [
  agentTool(
    "events.topics",
    "List the events installed plugins can wake you with: plugin, event, description, and payloadSchema (the fields a filter can use). Filter by query (plugin or event name). If nothing fits, find a plugin with plugins.search.",
    TopicsArgs,
    (tool, args) => topics(tool, Schema.decodeUnknownSync(TopicsArgs)(args))
  ),
  agentTool(
    "events.subscribe",
    'Wake up when a plugin event happens. Each match arrives as a hidden <codevisor-event type="plugin.event"> message: it wakes you when idle, or waits for the end of your turn. filter is a CEL expression over the event payload, type-checked against the payloadSchema from events.topics, e.g. labels.severity == "critical" && labels.env in ["prod", "staging"]. Omit it to get every event. Check a filter with events.preview first. note is a short human description of why you subscribed. The result has explained: read it back to the user in plain words. once: true removes the subscription after the first match. Subscriptions survive restarts; events wait while your Mac sleeps and arrive on wake.',
    SubscribeArgs,
    (tool, args) => subscribe(tool, Schema.decodeUnknownSync(SubscribeArgs)(args))
  ),
  agentTool(
    "events.preview",
    "Dry-run a filter: type-check it against the event's payloadSchema and match it against the plugin's recent events. Returns explained (plain English), scanned and matched counts.",
    PreviewArgs,
    (tool, args) => preview(tool, Schema.decodeUnknownSync(PreviewArgs)(args))
  ),
  agentTool(
    "events.subscriptions",
    "List the plugin event subscriptions you hold: subscriptionId, plugin, event, filter, explained, note, once, pausedReason.",
    NoArgs,
    (tool) => subscriptions(tool)
  ),
  agentTool(
    "events.unsubscribe",
    "Remove one of your plugin event subscriptions by subscriptionId.",
    SubscriptionIdArgs,
    (tool, args) =>
      unsubscribe(tool, Schema.decodeUnknownSync(SubscriptionIdArgs)(args).subscriptionId)
  ),
  agentTool(
    "events.get",
    "Read the full payload of a delivered plugin event by eventId (from the event message).",
    EventIdArgs,
    (tool, args) => getEvent(tool, Schema.decodeUnknownSync(EventIdArgs)(args).eventId)
  )
]

const topics = async (tool: AgentToolContext, args: typeof TopicsArgs.Type): Promise<unknown> => {
  const query = args.query === undefined ? "" : `?query=${encodeURIComponent(args.query)}`
  const listed = Schema.decodeUnknownSync(Schema.Struct({ types: Schema.Array(PluginEventType) }))(
    await tool.api("GET", `/v1/plugins/events/types${query}`)
  )
  return { items: listed.types.map(topicItem) }
}

const subscribe = async (
  tool: AgentToolContext,
  args: typeof SubscribeArgs.Type
): Promise<unknown> => {
  const sessionId = localCallerId(tool, "events.subscribe")
  const created = await tool.api("POST", "/v1/plugins/events/subscriptions", {
    body: {
      sessionId,
      plugin: args.plugin,
      event: args.event,
      note: args.note,
      ...(args.filter === undefined ? {} : { filter: args.filter }),
      ...(args.arguments === undefined ? {} : { arguments: args.arguments }),
      ...(args.account === undefined ? {} : { accountId: args.account }),
      ...(args.once === undefined ? {} : { once: args.once })
    }
  })
  return subscriptionItem(Schema.decodeUnknownSync(PluginEventSubscription)(created))
}

const preview = async (tool: AgentToolContext, args: typeof PreviewArgs.Type): Promise<unknown> =>
  tool.api("POST", "/v1/plugins/events/preview", {
    body: {
      plugin: args.plugin,
      event: args.event,
      ...(args.filter === undefined ? {} : { filter: args.filter }),
      ...(args.account === undefined ? {} : { accountId: args.account })
    }
  })

const subscriptions = async (tool: AgentToolContext): Promise<unknown> => {
  const sessionId = localCallerId(tool, "events.subscriptions")
  const held = Schema.decodeUnknownSync(
    Schema.Struct({ subscriptions: Schema.Array(PluginEventSubscription) })
  )(
    await tool.api(
      "GET",
      `/v1/plugins/events/subscriptions?sessionId=${encodeURIComponent(sessionId)}`
    )
  )
  return { items: held.subscriptions.map(subscriptionItem) }
}

const unsubscribe = async (tool: AgentToolContext, subscriptionId: string): Promise<unknown> => {
  localCallerId(tool, "events.unsubscribe")
  await tool.api("DELETE", `/v1/plugins/events/subscriptions/${encodeURIComponent(subscriptionId)}`)
  return { subscriptionId, removed: true }
}

const getEvent = (tool: AgentToolContext, eventId: string): Promise<unknown> =>
  tool.api("GET", `/v1/plugins/events/${encodeURIComponent(eventId)}`)

const topicItem = (type: PluginEventType) => ({
  plugin: type.pluginName,
  event: type.name,
  ...(type.description === undefined ? {} : { description: type.description }),
  ...(type.payloadSchema === undefined ? {} : { payloadSchema: type.payloadSchema }),
  ...(type.inputSchema === undefined ? {} : { arguments: type.inputSchema })
})

const subscriptionItem = (subscription: PluginEventSubscription) => ({
  subscriptionId: subscription.id,
  plugin: subscription.pluginName,
  event: subscription.event,
  ...(subscription.filter === undefined ? {} : { filter: subscription.filter }),
  explained: subscription.explained,
  ...(subscription.note === undefined ? {} : { note: subscription.note }),
  once: subscription.once,
  ...(subscription.pausedReason === undefined ? {} : { pausedReason: subscription.pausedReason })
})
