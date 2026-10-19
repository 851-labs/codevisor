import {
  CreateSessionSubscriptionRequest,
  DEFAULT_EXECUTION_JOB_WAIT_TIMEOUT_MS,
  WaitForExecutionJobRequest
} from "@codevisor/api"

import { apiTool, type CodevisorApiToolSpec } from "./codevisor-api-tool-spec.js"

export const codevisorJobApiTools: ReadonlyArray<CodevisorApiToolSpec> = [
  apiTool(
    "jobs.list",
    "List a session's background execute jobs (defaults to the calling session): jobId, description, state (running, completed, failed, cancelled), elapsedMs, the tool calls still running, the latest status() text, recent console logs, and outputPath. An execute call that outlives its timeout_ms keeps running as one of these jobs.",
    "GET",
    "/v1/sessions/:id/jobs"
  ),
  apiTool(
    "jobs.get",
    "Get one background execute job with its progress, recent logs, outputPath, and, once it has finished, its result or error. Reading a finished job's result here means Codevisor won't also send you its execution.job_finished event.",
    "GET",
    "/v1/jobs/:jobId"
  ),
  apiTool(
    "jobs.wait",
    "Wait for a background execute job to finish. Returns the job (with its result once finished) and timedOut when it is still running. timeoutMs defaults to 60000 and is shortened to fit what is left of this execute call's own budget, so the wait returns cleanly instead of being cut off; clampedToMs reports when that happened. Call again to keep waiting, or end your turn: Codevisor sends you an execution.job_finished event when the job ends.",
    "POST",
    "/v1/jobs/:jobId/wait",
    {
      body: WaitForExecutionJobRequest,
      budgetedWait: { field: "timeoutMs", defaultMs: DEFAULT_EXECUTION_JOB_WAIT_TIMEOUT_MS }
    }
  ),
  apiTool(
    "jobs.cancel",
    "Cancel a running background execute job and its pending tool calls. Returns the job's final state.",
    "POST",
    "/v1/jobs/:jobId/cancel"
  ),
  apiTool(
    "sessions.subscribe",
    "Subscribe the calling session (or sessionId) to another session's events. Each event arrives as a hidden <codevisor-event> message: it wakes this session with a new turn when it is idle, or waits for the end of its current turn, and the user never sees it as something they typed. events picks from turn_ended (with its final reply), waiting_for_user (a question or plan approval, with the question), errored, and job_finished (one of its background execute jobs ended); it defaults to turn_ended, waiting_for_user, and errored. once: true removes the subscription after its first event, for \"tell me when this one finishes\". Use it instead of polling sessions.wait, especially for agents you didn't create.",
    "POST",
    "/v1/sessions/:id/subscriptions",
    { body: CreateSessionSubscriptionRequest }
  ),
  apiTool(
    "sessions.subscriptions",
    "List the event subscriptions the calling session (or sessionId) holds, with their ids, targets, events, and whether they are one-shot.",
    "GET",
    "/v1/sessions/:id/subscriptions"
  ),
  apiTool(
    "sessions.unsubscribe",
    "Remove one of the calling session's event subscriptions by subscriptionId (from sessions.subscribe, sessions.subscriptions, or the subscriptionId on a delivered event).",
    "DELETE",
    "/v1/sessions/:id/subscriptions/:subscriptionId"
  )
]
