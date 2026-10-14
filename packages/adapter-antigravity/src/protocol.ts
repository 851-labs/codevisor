/// The slice of agy's headless stream-json protocol this adapter speaks
/// (`agy --input-format=stream-json --output-format=stream-json`): one user
/// line in, `init` once, then `step_update`s and a `result` per turn. Shapes
/// follow Google's headless docs for Antigravity CLI 1.3.x; every value agy
/// produces is open, so unknown step types and states pass through.

/// The oldest agy whose headless mode takes `--effort` and waits on a turn
/// with no print timeout by default.
export const MINIMUM_AGY_VERSION = "1.3.0"

export interface AgyUsage {
  readonly input_tokens?: number
  readonly output_tokens?: number
  readonly thinking_tokens?: number
  readonly cache_read_tokens?: number
  readonly total_tokens?: number
}

export interface AgyToolInfo {
  readonly name?: string
  readonly parameters?: Record<string, unknown>
  readonly output?: string
  readonly error?: { readonly type?: string; readonly message?: string }
}

export interface AgySubagent {
  readonly type_name?: string
  readonly role?: string
  readonly conversation_id?: string
}

export interface AgyStep {
  readonly conversation_id?: string
  readonly step_index: number
  /// `ACTIVE`, `DONE` or `ERROR`; a step is re-sent as it settles.
  readonly state: string
  /// `user_input`, `agent_response`, `tool` (older builds: `tool_call`),
  /// `checkpoint`, …
  readonly step_type: string
  readonly tool_name?: string
  readonly text_delta?: string
  readonly usage?: AgyUsage
  readonly tool_info?: AgyToolInfo
  readonly subagent_info?: { readonly subagents?: ReadonlyArray<AgySubagent> }
}

export interface AgyResult {
  readonly conversation_id: string
  /// `SUCCESS`, `ERROR`, `CANCELED`, `INTERRUPTED`, …
  readonly status: string
  readonly response?: string
  readonly error?: string
  /// Session totals, not the turn's.
  readonly usage?: AgyUsage
  readonly denied_actions?: ReadonlyArray<{
    readonly action?: string
    readonly display_name?: string
  }>
}

export const record = (value: unknown): Record<string, unknown> =>
  typeof value === "object" && value !== null && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : {}

export const text = (value: unknown): string | undefined =>
  typeof value === "string" && value.length > 0 ? value : undefined

export const finite = (value: unknown): number | undefined =>
  typeof value === "number" && Number.isFinite(value) ? value : undefined

/// agy's tool parameters are PascalCase (`TargetFile`); a few builds and
/// tools use camelCase. The first present spelling wins.
export const param = (parameters: Record<string, unknown>, ...names: Array<string>): unknown => {
  for (const name of names) {
    if (parameters[name] !== undefined) return parameters[name]
    const camel = name.charAt(0).toLowerCase() + name.slice(1)
    if (parameters[camel] !== undefined) return parameters[camel]
  }
  return undefined
}

const versionParts = (value: string) =>
  value.split(/[.-]/).map((part) => Number.parseInt(part, 10) || 0)

export const versionAtLeast = (version: string, minimum: string): boolean => {
  const have = versionParts(version)
  const want = versionParts(minimum)
  for (let index = 0; index < want.length; index += 1) {
    const difference = (have[index] ?? 0) - want[index]!
    if (difference !== 0) return difference > 0
  }
  return true
}

/// What agy says when nobody is signed in (`authentication failed or timed
/// out`, `Please sign in to view available models`, …).
export const signedOut = (message: string): boolean =>
  /authenticat|sign in|not logged in|log in/i.test(message)

export const SIGN_IN_DETAIL = "Sign in to Antigravity to continue."
