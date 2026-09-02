import {
  CancelRequest,
  CreateSessionRequest,
  MarkSessionReadRequest,
  OpenSessionRequest,
  PromptRequest,
  SetConfigRequest,
  SetGoalRequest,
  SetModeRequest,
  SetQuestionAnswerRequest,
  TerminalCreateRequest,
  UpdateQueuedPromptRequest,
  UpdateSessionRequest
} from "@codevisor/api"
import {
  stringQuery,
  integerQuery,
  apiTool,
  type CodevisorApiToolSpec
} from "./codevisor-api-tool-spec.js"

/// Session, terminal, and file tools.
export const codevisorSessionApiTools: ReadonlyArray<CodevisorApiToolSpec> = [
  apiTool("sessions.list", "List Codevisor sessions on this server.", "GET", "/v1/sessions"),
  apiTool("sessions.create", "Create a Codevisor coding-agent session.", "POST", "/v1/sessions", {
    body: CreateSessionRequest
  }),
  apiTool(
    "sessions.get",
    "Get a session, its current conversation, queue, and goal.",
    "GET",
    "/v1/sessions/:id"
  ),
  apiTool(
    "sessions.open",
    "Create or open a session and return its first transcript page.",
    "POST",
    "/v1/sessions/:id/open",
    {
      body: OpenSessionRequest
    }
  ),
  apiTool(
    "sessions.update",
    "Rename, archive, move, or reconfigure a session.",
    "PATCH",
    "/v1/sessions/:id",
    {
      body: UpdateSessionRequest
    }
  ),
  apiTool("sessions.delete", "Delete a Codevisor session.", "DELETE", "/v1/sessions/:id"),
  apiTool(
    "sessions.connect",
    "Ensure the session's underlying agent runtime is connected.",
    "POST",
    "/v1/sessions/:id/connect"
  ),
  apiTool(
    "sessions.usage_limits",
    "Read account usage limits for a session's harness.",
    "GET",
    "/v1/sessions/:id/usage-limits"
  ),
  apiTool(
    "sessions.branch_diff",
    "Get added and removed line totals for a session workspace.",
    "GET",
    "/v1/sessions/:id/branch-diff"
  ),
  apiTool(
    "sessions.transcript",
    "Read a reverse-paginated session transcript.",
    "GET",
    "/v1/sessions/:id/transcript",
    {
      query: [integerQuery("before", "Exclusive transcript cursor."), integerQuery("limit")]
    }
  ),
  apiTool(
    "sessions.transcript_details",
    "Read the detailed events for one transcript item.",
    "GET",
    "/v1/sessions/:id/transcript/:itemId/details"
  ),
  apiTool(
    "sessions.events",
    "Read the persisted event history for a session.",
    "GET",
    "/v1/sessions/:id/events"
  ),
  apiTool(
    "sessions.queue_list",
    "List queued prompts for a session.",
    "GET",
    "/v1/sessions/:id/queue"
  ),
  apiTool(
    "sessions.queue_update",
    "Edit a queued prompt before it starts.",
    "PATCH",
    "/v1/sessions/:id/queue/:queueId",
    {
      body: UpdateQueuedPromptRequest
    }
  ),
  apiTool(
    "sessions.queue_delete",
    "Remove a queued prompt.",
    "DELETE",
    "/v1/sessions/:id/queue/:queueId"
  ),
  apiTool(
    "sessions.prompt",
    "Send or queue a prompt in a Codevisor session.",
    "POST",
    "/v1/sessions/:id/prompt",
    {
      body: PromptRequest
    }
  ),
  apiTool(
    "sessions.cancel",
    "Cancel the active turn in a session.",
    "POST",
    "/v1/sessions/:id/cancel",
    {
      body: CancelRequest
    }
  ),
  apiTool("sessions.mode_set", "Set a session's agent mode.", "POST", "/v1/sessions/:id/mode", {
    body: SetModeRequest
  }),
  apiTool(
    "sessions.config_set",
    "Set one session configuration option.",
    "POST",
    "/v1/sessions/:id/config",
    {
      body: SetConfigRequest
    }
  ),
  apiTool(
    "sessions.goal_set",
    "Create or update a persistent session goal.",
    "POST",
    "/v1/sessions/:id/goal",
    {
      body: SetGoalRequest
    }
  ),
  apiTool(
    "sessions.goal_clear",
    "Clear a session's persistent goal.",
    "DELETE",
    "/v1/sessions/:id/goal"
  ),
  apiTool(
    "sessions.question_answer",
    "Answer or cancel a blocking agent question.",
    "POST",
    "/v1/sessions/:id/questions/:questionId/answer",
    {
      body: SetQuestionAnswerRequest
    }
  ),
  apiTool(
    "sessions.mark_read",
    "Mark session attention events as read.",
    "POST",
    "/v1/sessions/:id/read",
    {
      body: MarkSessionReadRequest
    }
  ),
  apiTool(
    "sessions.mark_unread",
    "Mark a session manually unread.",
    "POST",
    "/v1/sessions/:id/unread"
  ),
  apiTool(
    "sessions.plan_approval_clear",
    "Clear a pending plan-approval state.",
    "DELETE",
    "/v1/sessions/:id/plan-approval"
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
