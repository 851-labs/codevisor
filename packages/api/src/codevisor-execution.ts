/// Live annotation of a Codevisor gateway `execute` call. The gateway emits
/// it on the session sink; the server attaches it to the harness tool row as
/// `_meta.codevisorExecution` so clients can label what a workflow is doing.

/// What a workflow touched, so clients can draw its artwork: the site a
/// browser call left its tab on, the MCP server a call reached, or one of
/// Codevisor's own capabilities.
export type CodevisorExecutionIcon =
  | { readonly kind: "site"; readonly origin: string }
  | {
      readonly kind: "mcp"
      readonly serverId: string
      /// The server's host, so the icon still resolves (by favicon) once
      /// the server is removed or when it lives on another machine.
      readonly host?: string
    }
  | { readonly kind: "builtin"; readonly id: "browser" | "computer" | "codevisor" | "plugin" }

/// A file a workflow call produced (a screenshot, recording, or export),
/// stored as a server attachment the transcript can show.
export interface CodevisorExecutionFile {
  readonly fileId: string
  readonly name?: string
  readonly mimeType?: string
}

export interface CodevisorExecutionCall {
  readonly path: string
  /// The tool's display title ("Search models"), when it declares one.
  readonly title?: string
  /// What the call touched, for the step's icon.
  readonly icon?: CodevisorExecutionIcon
  /// Files the call produced.
  readonly files?: ReadonlyArray<CodevisorExecutionFile>
  /// Display name of the machine the call was routed to, when not local.
  readonly machine?: string
  readonly ok: boolean
  readonly ms: number
  readonly error?: string
}

export interface CodevisorExecutionState {
  readonly state: "running" | "completed" | "failed"
  /// The workflow's label (`execute`'s `description`), for rows whose own
  /// arguments don't carry it: a harness that ran the gateway from inside
  /// its own code tool (OpenCode's Code Mode).
  readonly description?: string
  readonly status?: string
  readonly calls: ReadonlyArray<CodevisorExecutionCall>
  readonly error?: string
  /// The first thing the workflow touched, which names it once it settles.
  readonly icon?: CodevisorExecutionIcon
  /// What the workflow is touching now (the latest call to start, or the
  /// site a browser call left its tab on), shown while it runs.
  readonly activeIcon?: CodevisorExecutionIcon
}

/// A gateway `skills` call, for rows that ran it from inside their own code
/// (OpenCode's Code Mode) and so can't show its arguments.
export interface CodevisorSkillRead {
  /// The skill read; absent when the call listed every skill.
  readonly name?: string
  readonly ok: boolean
}

export const CODEVISOR_EXECUTION_MAX_DESCRIPTION = 80
export const CODEVISOR_EXECUTION_MAX_STATUS = 120
export const CODEVISOR_EXECUTION_MAX_ERROR = 200
export const CODEVISOR_EXECUTION_MAX_CALLS = 50
export const CODEVISOR_EXECUTION_MAX_FILES = 12

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
