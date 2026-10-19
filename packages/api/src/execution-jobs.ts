import { Schema } from "effect"

export const DEFAULT_EXECUTION_JOB_WAIT_TIMEOUT_MS = 60_000
export const MAX_EXECUTION_JOB_WAIT_TIMEOUT_MS = 300_000

export const ExecutionJobState = Schema.Literals(["running", "completed", "failed", "cancelled"])
export type ExecutionJobState = typeof ExecutionJobState.Type

export const ExecutionJob = Schema.Struct({
  jobId: Schema.String,
  sessionId: Schema.String,
  description: Schema.String,
  state: ExecutionJobState,
  startedAt: Schema.String,
  finishedAt: Schema.optional(Schema.String),
  elapsedMs: Schema.Number,
  running: Schema.Array(Schema.String),
  progress: Schema.optional(Schema.String),
  logs: Schema.Array(Schema.String),
  outputPath: Schema.String,
  result: Schema.optional(Schema.Unknown),
  error: Schema.optional(Schema.String)
})
export type ExecutionJob = typeof ExecutionJob.Type

export const ExecutionJobList = Schema.Struct({ jobs: Schema.Array(ExecutionJob) })
export type ExecutionJobList = typeof ExecutionJobList.Type

export const WaitForExecutionJobRequest = Schema.Struct({
  timeoutMs: Schema.optional(Schema.Number)
})
export type WaitForExecutionJobRequest = typeof WaitForExecutionJobRequest.Type

export const WaitForExecutionJobResponse = Schema.Struct({
  job: ExecutionJob,
  timedOut: Schema.Boolean
})
export type WaitForExecutionJobResponse = typeof WaitForExecutionJobResponse.Type
