import {
  AgentArchiveResult,
  AgentList,
  AgentState,
  DEFAULT_SESSION_WAIT_TIMEOUT_MS,
  SessionEventType,
  SessionSubscription,
  TranscriptPage,
  WaitForAgentsResponse
} from "@codevisor/api"
import { Schema } from "effect"

import { agentSummary, localCallerId } from "./codevisor-agent-caller.js"
import { agentTool, type AgentTool, type AgentToolContext } from "./codevisor-agent-tool.js"
import { apiTool } from "./codevisor-api-tool-spec.js"
import { namedRecord } from "./codevisor-tool-shapes.js"
import { budgetedWaitPayload } from "./codevisor-wait-budget.js"

const ListAgentsArgs = Schema.Struct({
  state: Schema.optional(AgentState),
  project: Schema.optional(Schema.String),
  label: Schema.optional(Schema.String),
  parentAgentId: Schema.optional(Schema.String),
  next: Schema.optional(Schema.String)
})
const AgentIdArgs = Schema.Struct({ agentId: Schema.String })
const SubscribeArgs = Schema.Struct({
  agentId: Schema.String,
  events: Schema.optional(Schema.Array(SessionEventType)),
  once: Schema.optional(Schema.Boolean)
})
const UnsubscribeArgs = Schema.Struct({ subscriptionId: Schema.String })
const NoArgs = Schema.Struct({})
const WaitArgs = Schema.Struct({
  agentIds: Schema.Array(Schema.String),
  until: Schema.optional(Schema.Array(AgentState)),
  timeoutMs: Schema.optional(Schema.Number)
})
const TranscriptArgs = Schema.Struct({
  agentId: Schema.String,
  next: Schema.optional(Schema.String),
  limit: Schema.optional(Schema.Number)
})

const listPageSize = 50
const waitBudget = apiTool("agents.wait", "", "POST", "/v1/agents/wait", {
  budgetedWait: { field: "timeoutMs", defaultMs: DEFAULT_SESSION_WAIT_TIMEOUT_MS }
})

export const codevisorAgentTools: ReadonlyArray<AgentTool> = [
  agentTool(
    "agents.list",
    "List agents on this machine, newest activity first, as slim summaries: agentId, title, state (working, waitingForUser, idle, errored), projectId, workspaceId, harness, labels, parentAgentId. Filter by state, project (id or name), label (key=value, or key for any value), or parentAgentId (the agents a given agent started). Pass next back for the next page.",
    ListAgentsArgs,
    (tool, args) => listAgents(tool, Schema.decodeUnknownSync(ListAgentsArgs)(args))
  ),
  agentTool(
    "agents.archive",
    "Archive the workspace of an agent you started once its work is merged or no longer needed, and wait until it is done. Its chats stop, its branch name is released, and its checkout is kept as a restorable snapshot; ignored files such as tmp/ screenshots are kept too, listed in keptArtifacts, and come back on restore. If the archive fails, this call fails and the checkout stays in place. Push or open the PR first if the branch should stay. Refuses an agent that shares your own workspace.",
    AgentIdArgs,
    (tool, args) => archiveAgent(tool, Schema.decodeUnknownSync(AgentIdArgs)(args).agentId)
  ),
  agentTool(
    "agents.subscribe",
    "Subscribe to events of an agent you didn't start (agents.start subscribes you already). Each event arrives as a hidden <codevisor-event> message: it wakes you when idle, or waits for the end of your turn. events picks from turn_ended (with the complete final reply), waiting_for_user (with the question), errored, and job_finished; it defaults to the first three. once: true removes the subscription after its first event.",
    SubscribeArgs,
    (tool, args) => subscribe(tool, Schema.decodeUnknownSync(SubscribeArgs)(args))
  ),
  agentTool(
    "agents.subscriptions",
    "List the event subscriptions you hold: subscriptionId, agentId, events, once.",
    NoArgs,
    (tool) => subscriptions(tool)
  ),
  agentTool(
    "agents.unsubscribe",
    "Remove one of your event subscriptions by subscriptionId (from agents.subscriptions or a delivered event).",
    UnsubscribeArgs,
    (tool, args) =>
      unsubscribe(tool, Schema.decodeUnknownSync(UnsubscribeArgs)(args).subscriptionId)
  ),
  agentTool(
    "agents.wait",
    "Wait inside this call until any listed agent reaches one of the until states (default idle, waitingForUser, errored). Returns every listed agent's state (an idle agent with live background tasks counts as working, and an idle one with queued messages hasn't settled) and pendingQuestion, and timedOut when none matched in time. timeoutMs defaults to 60000, is capped at 300000, and shrinks to fit this execute call's budget (clampedToMs). For anything longer than a minute or two, end your turn and let the event arrive instead.",
    WaitArgs,
    (tool, args) => waitForAgents(tool, Schema.decodeUnknownSync(WaitArgs)(args))
  ),
  agentTool(
    "agents.debug.transcript",
    "Read an agent's raw transcript, newest page first; items are oldest to newest within a page. Pass next back for the next older page. Prefer agents.status and agents.debug.search.",
    TranscriptArgs,
    (tool, args) => transcript(tool, Schema.decodeUnknownSync(TranscriptArgs)(args))
  )
]

const listAgents = async (
  tool: AgentToolContext,
  args: typeof ListAgentsArgs.Type
): Promise<unknown> => {
  const listed = Schema.decodeUnknownSync(AgentList)(
    await tool.api("GET", "/v1/agents", {
      query: {
        state: args.state,
        project: args.project,
        label: args.label,
        parentAgentId: args.parentAgentId
      }
    })
  )
  const offset = pageOffset(args.next)
  const nextOffset = offset + listPageSize
  return {
    items: listed.items.slice(offset, nextOffset),
    ...(nextOffset < listed.items.length ? { next: String(nextOffset) } : {})
  }
}

const pageOffset = (next: string | undefined): number => {
  const offset = Number(next ?? 0)
  if (!Number.isSafeInteger(offset) || offset < 0)
    throw new Error("next must come from an earlier agents.list")
  return offset
}

const archiveAgent = async (tool: AgentToolContext, agentId: string): Promise<unknown> => {
  const agent = await agentSummary(tool, agentId)
  if (agent.workspaceId === undefined)
    throw new Error(`Agent ${agentId} has no workspace to archive`)
  if (await sharesCallerWorkspace(tool, agent.workspaceId)) {
    throw new Error(`Agent ${agentId} shares your workspace; archiving it would archive you too`)
  }
  return Schema.decodeUnknownSync(AgentArchiveResult)(
    await tool.api("POST", `/v1/agents/${encodeURIComponent(agent.id)}/archive`)
  )
}

const sharesCallerWorkspace = async (
  tool: AgentToolContext,
  workspaceId: string
): Promise<boolean> => {
  if (tool.context.sessionId.startsWith("remote:")) return false
  const caller = await agentSummary(tool, tool.context.sessionId)
  return caller.workspaceId?.toLowerCase() === workspaceId.toLowerCase()
}

const subscribe = async (
  tool: AgentToolContext,
  args: typeof SubscribeArgs.Type
): Promise<unknown> => {
  const callerId = localCallerId(tool, "agents.subscribe")
  const created = await tool.api(
    "POST",
    `/v1/sessions/${encodeURIComponent(callerId)}/subscriptions`,
    {
      body: {
        targetSessionId: args.agentId,
        ...(args.events === undefined ? {} : { events: args.events }),
        ...(args.once === undefined ? {} : { once: args.once })
      }
    }
  )
  return subscriptionItem(Schema.decodeUnknownSync(SessionSubscription)(created))
}

const subscriptions = async (tool: AgentToolContext): Promise<unknown> => {
  const callerId = localCallerId(tool, "agents.subscriptions")
  const held = Schema.decodeUnknownSync(
    Schema.Struct({ subscriptions: Schema.Array(SessionSubscription) })
  )(await tool.api("GET", `/v1/sessions/${encodeURIComponent(callerId)}/subscriptions`))
  return { items: held.subscriptions.map(subscriptionItem) }
}

const unsubscribe = async (tool: AgentToolContext, subscriptionId: string): Promise<unknown> => {
  const callerId = localCallerId(tool, "agents.unsubscribe")
  await tool.api(
    "DELETE",
    `/v1/sessions/${encodeURIComponent(callerId)}/subscriptions/${encodeURIComponent(subscriptionId)}`
  )
  return { subscriptionId, removed: true }
}

const subscriptionItem = (subscription: SessionSubscription) => ({
  subscriptionId: subscription.id,
  agentId: subscription.targetSessionId,
  events: subscription.events,
  once: subscription.once,
  createdAt: subscription.createdAt
})

const waitForAgents = async (
  tool: AgentToolContext,
  args: typeof WaitArgs.Type
): Promise<unknown> => {
  const request = budgetedWaitPayload(waitBudget, args, tool.context)
  const waited = Schema.decodeUnknownSync(WaitForAgentsResponse)(
    await tool.api("POST", "/v1/agents/wait", { body: request.payload })
  )
  return {
    ...waited,
    ...(request.clampedToMs === undefined ? {} : { clampedToMs: request.clampedToMs })
  }
}

const transcript = async (
  tool: AgentToolContext,
  args: typeof TranscriptArgs.Type
): Promise<unknown> => {
  const page = Schema.decodeUnknownSync(TranscriptPage)(
    await tool.api("GET", `/v1/sessions/${encodeURIComponent(args.agentId)}/transcript`, {
      query: { before: args.next, limit: args.limit === undefined ? undefined : String(args.limit) }
    })
  )
  return {
    items: page.items.map((item) => namedRecord(item, "itemId")),
    ...(page.hasMore && page.nextBefore !== undefined ? { next: page.nextBefore } : {})
  }
}
