import {
  AgentCallerDefaults,
  AgentIsolation,
  Labels,
  PromptDelivery,
  ReorderQueuedPromptsRequest,
  SetConfigRequest,
  SetGoalRequest,
  SetModeRequest,
  SetQuestionAnswerRequest,
  UpdateQueuedPromptRequest,
  UpdateSessionRequest
} from "@codevisor/api"
import { Schema } from "effect"

import {
  apiTool,
  integerQuery,
  stringQuery,
  type CodevisorApiToolSpec
} from "./codevisor-api-tool-spec.js"

const StartAgentBody = Schema.Struct({
  prompt: Schema.String,
  title: Schema.String,
  isolation: AgentIsolation,
  harness: Schema.optional(Schema.String),
  model: Schema.optional(Schema.String),
  project: Schema.optional(Schema.String),
  labels: Schema.optional(Labels),
  callerDefaults: Schema.optional(AgentCallerDefaults)
})

const MessageAgentBody = Schema.Struct({
  text: Schema.String,
  delivery: Schema.optional(PromptDelivery)
})

const AgentLabelsBody = Schema.Struct({
  title: UpdateSessionRequest.fields.title,
  labels: UpdateSessionRequest.fields.labels
})

export const codevisorAgentApiTools: ReadonlyArray<CodevisorApiToolSpec> = [
  apiTool(
    "agents.start",
    'Start another agent as a visible Codevisor chat and give it its first message, in one call. isolation picks its checkout: worktree (a new git worktree and workspace, for separate work that ends in its own branch or PR), shared (your own workspace and checkout, for a second opinion or a piece of your change), or project (the project folder in a new workspace). harness, model, reasoning, and project default to yours. You are subscribed to its events: its final reply arrives as a hidden <codevisor-event type="session.turn_ended"> message, so end your turn instead of waiting. labels (string key/value pairs) let you find it again with agents.list. If any step fails, Codevisor removes what this call created and returns the error.',
    "POST",
    "/v1/agents",
    { body: StartAgentBody }
  ),
  apiTool(
    "agents.message",
    "Send a follow-up message to an agent. An idle agent starts a turn with it. While it is working, delivery picks how it lands: steer (the default) adds it to the running turn, so the agent reads it at its next step; queue holds it until the turn and any earlier queued messages finish. Messages go in the order you sent them: a steer first delivers anything you queued earlier, in order. delivered reports what happened: sent, steered, or queued. steerDeclined: true means the running turn couldn't take it (its harness can't steer, or is updating), so it was queued.",
    "POST",
    "/v1/sessions/:id/prompt",
    { body: MessageAgentBody }
  ),
  apiTool(
    "agents.status",
    "Read an agent's state (working, waitingForUser, idle, errored), its complete last reply, and its pendingQuestion while it waits for an answer. working means its turn isn't done yet; background work it left running, such as a dev server, doesn't count.",
    "GET",
    "/v1/agents/:id"
  ),
  apiTool(
    "agents.answer",
    "Answer (outcome: answered, with answers keyed by question id) or cancel (outcome: cancelled) the pendingQuestion an agent is waiting on. Get the questionId and questions from agents.status.",
    "POST",
    "/v1/sessions/:id/questions/:questionId/answer",
    { body: SetQuestionAnswerRequest }
  ),
  apiTool("agents.cancel", "Stop an agent's running turn.", "POST", "/v1/sessions/:id/cancel"),
  apiTool(
    "agents.debug.search",
    "Search an agent's transcript, newest first. Returns snippets with itemIds; read one in full with agents.debug.item. query matches text case-insensitively; kinds (comma-separated user, assistant, tool, event) and tool (part of a tool's title or kind) narrow it; last caps the hits (default 20, at most 200). Pass next back to continue to older hits. Talk to the agent first; use this only to debug it.",
    "GET",
    "/v1/agents/:id/search",
    {
      query: [
        stringQuery("query", "Text to find, case-insensitive. Omit to list the newest items."),
        stringQuery("kinds", "Comma-separated kinds: user, assistant, tool, event."),
        stringQuery("tool", "Only tool calls whose title or kind contains this."),
        integerQuery("last", "Maximum hits, from 1 to 200. Defaults to 20."),
        stringQuery("next", "Cursor from a previous search's next.")
      ]
    }
  ),
  apiTool(
    "agents.debug.item",
    "Read one transcript item in full by the itemId from agents.debug.search: a message's whole text, or a tool call's title, status, complete input, and complete output.",
    "GET",
    "/v1/agents/:id/items/:itemId"
  ),
  apiTool(
    "agents.debug.queue",
    "List the messages waiting in an agent's queue.",
    "GET",
    "/v1/sessions/:id/queue"
  ),
  apiTool(
    "agents.debug.queue_update",
    "Edit a queued message before it starts.",
    "PATCH",
    "/v1/sessions/:id/queue/:queueId",
    { body: UpdateQueuedPromptRequest }
  ),
  apiTool(
    "agents.debug.queue_reorder",
    "Reorder an agent's queued messages by listing every queueItemId in the order you want.",
    "PATCH",
    "/v1/sessions/:id/queue",
    { body: ReorderQueuedPromptsRequest }
  ),
  apiTool(
    "agents.debug.queue_delete",
    "Remove a queued message.",
    "DELETE",
    "/v1/sessions/:id/queue/:queueId"
  ),
  apiTool(
    "agents.debug.queue_send_now",
    "Send a queued message now: steered into the running turn when the harness allows it, otherwise moved to the front of the queue. Returns the same delivered and steerDeclined fields as agents.message.",
    "POST",
    "/v1/sessions/:id/queue/:queueId/send-now"
  ),
  apiTool(
    "agents.debug.state",
    "Read an agent's full state: its summary, recent conversation, queue, pending question, background tasks, goal, and plan.",
    "GET",
    "/v1/sessions/:id"
  ),
  apiTool(
    "agents.debug.update",
    "Rename an agent or replace its labels (an empty object clears them).",
    "PATCH",
    "/v1/sessions/:id",
    { body: AgentLabelsBody }
  ),
  apiTool(
    "agents.debug.branch_diff",
    "Get the added and removed line totals of an agent's workspace branch.",
    "GET",
    "/v1/sessions/:id/branch-diff"
  ),
  apiTool(
    "agents.debug.usage_limits",
    "Read the account usage limits of an agent's harness.",
    "GET",
    "/v1/sessions/:id/usage-limits"
  ),
  apiTool("agents.debug.mode_set", "Set an agent's mode.", "POST", "/v1/sessions/:id/mode", {
    body: SetModeRequest
  }),
  apiTool(
    "agents.debug.config_set",
    "Set one of an agent's configuration options, such as its model.",
    "POST",
    "/v1/sessions/:id/config",
    { body: SetConfigRequest }
  ),
  apiTool(
    "agents.debug.goal_set",
    "Create or update an agent's persistent goal.",
    "POST",
    "/v1/sessions/:id/goal",
    { body: SetGoalRequest }
  ),
  apiTool(
    "agents.debug.goal_clear",
    "Clear an agent's persistent goal.",
    "DELETE",
    "/v1/sessions/:id/goal"
  )
]
