import {
  AgentList,
  ArchivedAgent,
  DetachedAgent,
  AgentState,
  DEFAULT_SESSION_WAIT_TIMEOUT_MS,
  SessionEventType,
  SessionSubscription,
  TranscriptPage,
  WaitForAgentsResponse
} from "@codevisor/api"
import { Schema } from "effect"

import { hasNoLocalChat, localCallerId } from "./codevisor-agent-caller.js"
import { agentTool, type AgentTool, type AgentToolContext } from "./codevisor-agent-tool.js"
import { apiTool } from "./codevisor-api-tool-spec.js"
import { namedRecord } from "./codevisor-tool-shapes.js"
import { budgetedWaitPayload } from "./codevisor-wait-budget.js"

const ListAgentsArgs = Schema.Struct({
  state: Schema.optional(AgentState),
  project: Schema.optional(Schema.String),
  label: Schema.optional(Schema.String),
  createdByAgentId: Schema.optional(Schema.String),
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
    "List agents on this machine, newest activity first, as slim summaries: agentId, title, state (working, waitingForUser, idle, errored), projectId, workspaceId, harness, labels, createdByAgentId and createdByAgentMachineId, plus archived: true on one that was archived and standalone: true on one that stands alone. Filter by state, project (id or name), label (key=value, or key for any value), or createdByAgentId (the agents a given agent started). Pass next back for the next page.",
    ListAgentsArgs,
    (tool, args) => listAgents(tool, Schema.decodeUnknownSync(ListAgentsArgs)(args))
  ),
  agentTool(
    "agents.archive",
    'Archive an agent you started once you have what you need from it or its work is merged, and wait until it is done. It stops if still running, you stop getting its events, and its chat is archived: it takes no more messages and its tab closes. Cleanup depends on where it ran. A shared helper (checkout: "shared") ran in your checkout, so nothing on disk changes. A worktree agent\'s worktree is reclaimed when nothing else uses it: the branch name is released, tracked and untracked files are kept as a restorable snapshot, and everything else in the folder, ignored files included, is deleted, so push or open the PR first if the branch should stay. The project folder itself is never touched. If the archive fails, this call fails and nothing is removed. Refuses yourself.',
    AgentIdArgs,
    (tool, args) => archiveAgent(tool, Schema.decodeUnknownSync(AgentIdArgs)(args).agentId)
  ),
  agentTool(
    "agents.detach",
    "Let go of an agent you started, so it stands alone as its own item in the user's sidebar: use it when its work has become the user's to follow, not a step in yours. It leaves your agents pill and is no longer archived when you are. A helper sharing your workspace moves into a workspace of its own, on the same checkout. You can still message it, subscribe to it, and archive it. This can't be undone. Returns agentId, workspaceId and detached: true.",
    AgentIdArgs,
    (tool, args) => detachAgent(tool, Schema.decodeUnknownSync(AgentIdArgs)(args).agentId)
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
    "Wait inside this call until any listed agent reaches one of the until states (default idle, waitingForUser, errored). Returns every listed agent's state (background work an agent left running doesn't count as working, and an idle one with queued messages hasn't settled) and pendingQuestion, and timedOut when none matched in time. timeoutMs defaults to 60000, is capped at 300000, and shrinks to fit this execute call's budget (clampedToMs). For anything longer than a minute or two, end your turn and let the event arrive instead.",
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
        createdByAgentId: args.createdByAgentId
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

const archiveAgent = async (tool: AgentToolContext, agentId: string): Promise<unknown> =>
  Schema.decodeUnknownSync(ArchivedAgent)(
    await tool.api("POST", `/v1/agents/${encodeURIComponent(agentId)}/archive`, {
      body: archiveCaller(tool)
    })
  )

const detachAgent = async (tool: AgentToolContext, agentId: string): Promise<unknown> =>
  Schema.decodeUnknownSync(DetachedAgent)(
    await tool.api("POST", `/v1/agents/${encodeURIComponent(agentId)}/detach`, { body: {} })
  )

const archiveCaller = (tool: AgentToolContext) => {
  if (hasNoLocalChat(tool.context.sessionId)) return {}
  return { callerAgentId: tool.context.sessionId }
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
