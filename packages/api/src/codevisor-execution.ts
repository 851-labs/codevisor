/// Live annotation of a Codevisor gateway `execute` call. The gateway emits
/// it on the session sink; the server attaches it to the harness tool row as
/// `_meta.codevisorExecution` so clients can label what a workflow is doing.

export interface CodevisorExecutionCall {
  readonly path: string
  /// Display name of the machine the call was routed to, when not local.
  readonly machine?: string
  readonly ok: boolean
  readonly ms: number
  readonly error?: string
}

export interface CodevisorExecutionState {
  readonly state: "running" | "completed" | "failed"
  readonly status?: string
  readonly calls: ReadonlyArray<CodevisorExecutionCall>
  readonly error?: string
}

export const CODEVISOR_EXECUTION_MAX_DESCRIPTION = 80
export const CODEVISOR_EXECUTION_MAX_STATUS = 120
export const CODEVISOR_EXECUTION_MAX_ERROR = 200
export const CODEVISOR_EXECUTION_MAX_CALLS = 50

const canonicalize = (value: unknown): unknown => {
  if (Array.isArray(value)) return value.map(canonicalize)
  if (value !== null && typeof value === "object") {
    // oxlint-disable-next-line unicorn/no-array-sort -- a fresh keys array; the web app's lib target predates toSorted
    const keys = Object.keys(value).sort()
    return Object.fromEntries(
      keys.map((key) => [key, canonicalize((value as Record<string, unknown>)[key])])
    )
  }
  return value
}

/// Canonical JSON of the execute arguments (keys sorted recursively). The
/// gateway and the server both hash this to correlate a gateway execution
/// with the harness tool call that carried the same arguments.
export const canonicalExecutionArgs = (args: unknown): string =>
  JSON.stringify(canonicalize(args)) ?? "null"
