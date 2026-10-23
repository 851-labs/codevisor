import { DEFAULT_EXECUTION_JOB_WAIT_TIMEOUT_MS, WaitForExecutionJobRequest } from "@codevisor/api"

import { apiTool, type CodevisorApiToolSpec } from "./codevisor-api-tool-spec.js"

export const codevisorJobApiTools: ReadonlyArray<CodevisorApiToolSpec> = [
  apiTool(
    "jobs.list",
    "List an agent's background execute jobs (defaults to you): jobId, description, state (running, completed, failed, cancelled), elapsedMs, the tool calls still running, the latest status() text, recent console logs, and outputPath. An execute call that outlives its timeout_ms keeps running as one of these jobs.",
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
  )
]
