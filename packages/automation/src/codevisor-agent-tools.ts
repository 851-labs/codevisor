import {
  DEFAULT_SESSION_WAIT_TIMEOUT_MS,
  SessionEventType,
  SessionSubscription,
  SessionSummary,
  TranscriptPage,
  WaitForSessionsResponse,
  type SessionSidebarState
} from "@codevisor/api"
import { Schema } from "effect"

import { agentSummary, localCallerId } from "./codevisor-agent-caller.js"
import { resolveProjectId, startAgent, StartAgentArgs } from "./codevisor-agent-start.js"
import { agentTool, type AgentTool, type AgentToolContext } from "./codevisor-agent-tool.js"
import { apiTool } from "./codevisor-api-tool-spec.js"
import { namedRecord } from "./codevisor-tool-shapes.js"
import { budgetedWaitPayload } from "./codevisor-wait-budget.js"

const AgentState = Schema.Literals(["working", "waitingForUser", "idle", "errored"])
type AgentState = typeof AgentState.Type

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
const waitBudget = apiTool("agents.wait", "", "POST", "/v1/sessions/wait", {
  budgetedWait: { field: "timeoutMs", defaultMs: DEFAULT_SESSION_WAIT_TIMEOUT_MS }
})

export const codevisorAgentTools: ReadonlyArray<AgentTool> = [
  agentTool(
    "agents.start",
    'Start another agent as a visible Codevisor chat and give it its first message, in one call. isolation picks its checkout: worktree (a new git worktree and workspace, for separate work that ends in its own branch or PR), shared (your own workspace and checkout, for a second opinion or a piece of your change), or project (the project folder in a new workspace). harness, model, reasoning, and project default to yours. You are subscribed to its events: its final reply arrives as a hidden <codevisor-event type="session.turn_ended"> message, so end your turn instead of waiting. labels (string key/value pairs) let you find it again with agents.list.',
    StartAgentArgs,
    startAgent
  ),
  agentTool(
    "agents.list",
    "List agents on this machine, newest activity first, as slim summaries: agentId, title, state (working, waitingForUser, idle, errored), projectId, workspaceId, harness, labels, parentAgentId. Filter by state, project (id or name), label (key=value, or key for any value), or parentAgentId (the agents a given agent started). Pass next back for the next page.",
    ListAgentsArgs,
    (tool, args) => listAgents(tool, Schema.decodeUnknownSync(ListAgentsArgs)(args))
  ),
  agentTool(
    "agents.archive",
    "Archive the workspace of an agent you started once its work is merged or no longer needed. Its chats stop, its branch name is released, and its checkout is kept as a restorable snapshot; ignored files such as tmp/ screenshots are kept and come back on restore. Push or open the PR first if the branch should stay. Refuses an agent that shares your own workspace.",
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
    "Wait inside this call until any listed agent reaches one of the until states (default idle, waitingForUser, errored). Returns every listed agent's state and pendingQuestion, and timedOut when none matched in time. timeoutMs defaults to 60000, is capped at 300000, and shrinks to fit this execute call's budget (clampedToMs). For anything longer than a minute or two, end your turn and let the event arrive instead.",
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
  const listed = Schema.decodeUnknownSync(Schema.Array(SessionSummary))(
    await tool.api("GET", "/v1/sessions", {
      query: { parentSessionId: args.parentAgentId, label: args.label }
    })
  )
  const projectId = await listedProjectId(tool, args.project)
  const matching = listed.filter((session) => listedAgent(session, args.state, projectId))
  const offset = pageOffset(args.next)
  const page = matching.slice(offset, offset + listPageSize).map(agentListItem)
  const nextOffset = offset + listPageSize
  return { items: page, ...(nextOffset < matching.length ? { next: String(nextOffset) } : {}) }
}

const listedProjectId = async (
  tool: AgentToolContext,
  project: string | undefined
): Promise<string | undefined> => {
  if (project === undefined) return undefined
  return resolveProjectId(tool, project, {})
}

const listedAgent = (
  session: SessionSummary,
  state: AgentState | undefined,
  projectId: string | undefined
): boolean =>
  (state === undefined || summaryState(session) === state) &&
  (projectId === undefined || session.projectId === projectId)

const pageOffset = (next: string | undefined): number => {
  const offset = Number(next ?? 0)
  if (!Number.isSafeInteger(offset) || offset < 0)
    throw new Error("next must come from an earlier agents.list")
  return offset
}

const agentListItem = (session: SessionSummary) => ({
  agentId: session.id,
  title: session.title,
  state: summaryState(session),
  projectId: session.projectId,
  harness: session.harnessId,
  ...(session.workspaceId === undefined ? {} : { workspaceId: session.workspaceId }),
  ...(session.worktreeName === undefined ? {} : { worktreeName: session.worktreeName }),
  ...(session.labels === undefined ? {} : { labels: session.labels }),
  ...(session.parentSessionId === undefined ? {} : { parentAgentId: session.parentSessionId }),
  ...(session.updatedAt === undefined ? {} : { updatedAt: session.updatedAt })
})

const summaryState = (
  session: Pick<SessionSummary, "sidebarState" | "actionRequired">
): AgentState => sidebarAgentState(session.sidebarState, session.actionRequired === true)

const sidebarAgentState = (
  sidebar: SessionSidebarState | undefined,
  actionRequired: boolean
): AgentState => {
  if (sidebar === "errored") return "errored"
  if (sidebar === "waitingForUser" || actionRequired) return "waitingForUser"
  if (sidebar === "inProgress") return "working"
  return "idle"
}

const archiveAgent = async (tool: AgentToolContext, agentId: string): Promise<unknown> => {
  const agent = await agentSummary(tool, agentId)
  if (agent.workspaceId === undefined)
    throw new Error(`Agent ${agentId} has no workspace to archive`)
  if (await sharesCallerWorkspace(tool, agent.workspaceId)) {
    throw new Error(`Agent ${agentId} shares your workspace; archiving it would archive you too`)
  }
  await tool.api("PATCH", `/v1/workspaces/${encodeURIComponent(agent.workspaceId)}`, {
    body: { isArchived: true }
  })
  return { agentId: agent.id, workspaceId: agent.workspaceId, archived: true }
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

const untilStates: Readonly<Record<AgentState, ReadonlyArray<SessionSidebarState>>> = {
  working: ["inProgress"],
  waitingForUser: ["waitingForUser"],
  idle: ["idle"],
  errored: ["errored"]
}

const waitForAgents = async (
  tool: AgentToolContext,
  args: typeof WaitArgs.Type
): Promise<unknown> => {
  const request = budgetedWaitPayload(waitBudget, waitBody(args), tool.context)
  const waited = Schema.decodeUnknownSync(WaitForSessionsResponse)(
    await tool.api("POST", "/v1/sessions/wait", { body: request.payload })
  )
  return {
    items: waited.sessions.map((session) => ({
      agentId: session.id,
      state: sidebarAgentState(session.sidebarState, session.actionRequiredKind !== undefined),
      ...(session.pendingQuestion === undefined ? {} : { pendingQuestion: session.pendingQuestion })
    })),
    timedOut: waited.timedOut,
    ...(request.clampedToMs === undefined ? {} : { clampedToMs: request.clampedToMs })
  }
}

const waitBody = (args: typeof WaitArgs.Type) => ({
  ids: args.agentIds,
  ...(args.until === undefined ? {} : { until: args.until.flatMap((state) => untilStates[state]) }),
  ...(args.timeoutMs === undefined ? {} : { timeoutMs: args.timeoutMs })
})

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
