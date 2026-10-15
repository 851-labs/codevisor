import { isPlainRecord } from "@codevisor/api"

export const MINIMUM_AGY_VERSION = "1.3.0"

export interface AgyUsage {
  readonly input_tokens?: number | undefined
  readonly output_tokens?: number | undefined
  readonly thinking_tokens?: number | undefined
  readonly cache_read_tokens?: number | undefined
  readonly total_tokens?: number | undefined
}

export interface AgyToolInfo {
  readonly name?: string | undefined
  readonly parameters?: Record<string, unknown> | undefined
  readonly output?: string | undefined
  readonly error?:
    | { readonly type?: string | undefined; readonly message?: string | undefined }
    | undefined
}

export interface AgyStep {
  readonly conversation_id?: string | undefined
  readonly step_index: number
  readonly state: string
  readonly step_type: string
  readonly tool_name?: string | undefined
  readonly text_delta?: string | undefined
  readonly usage?: AgyUsage | undefined
  readonly tool_info?: AgyToolInfo | undefined
}

export interface AgyDeniedAction {
  readonly action?: string | undefined
  readonly display_name?: string | undefined
}

export interface AgyResult {
  readonly status: string
  readonly error?: string | undefined
  readonly usage?: AgyUsage | undefined
  readonly denied_actions: ReadonlyArray<AgyDeniedAction>
}

export const record = (value: unknown): Record<string, unknown> =>
  isPlainRecord(value) ? value : {}

export const text = (value: unknown): string | undefined =>
  typeof value === "string" && value.length > 0 ? value : undefined

const string = (value: unknown): string | undefined =>
  typeof value === "string" ? value : undefined

const number = (value: unknown): number | undefined =>
  typeof value === "number" ? value : undefined

export const finite = (value: unknown): number | undefined =>
  typeof value === "number" && Number.isFinite(value) ? value : undefined

export const messageOf = (cause: unknown): string =>
  cause instanceof Error ? cause.message : String(cause)

const usage = (value: unknown): AgyUsage => {
  const fields = record(value)
  return {
    input_tokens: number(fields.input_tokens),
    output_tokens: number(fields.output_tokens),
    thinking_tokens: number(fields.thinking_tokens),
    cache_read_tokens: number(fields.cache_read_tokens),
    total_tokens: number(fields.total_tokens)
  }
}

export const agyStep = (value: unknown): AgyStep | undefined => {
  const step = record(value)
  const stepIndex = number(step.step_index)
  if (stepIndex === undefined) return undefined
  const info = record(step.tool_info)
  const error = record(info.error)
  return {
    conversation_id: string(step.conversation_id),
    step_index: stepIndex,
    state: string(step.state) ?? "",
    step_type: string(step.step_type) ?? "",
    tool_name: string(step.tool_name),
    text_delta: string(step.text_delta),
    usage: usage(step.usage),
    tool_info: {
      name: string(info.name),
      parameters: record(info.parameters),
      output: string(info.output),
      error: { type: string(error.type), message: string(error.message) }
    }
  }
}

export const agyResult = (value: unknown): AgyResult => {
  const result = record(value)
  return {
    status: string(result.status) ?? "",
    error: string(result.error),
    usage: usage(result.usage),
    denied_actions: (Array.isArray(result.denied_actions) ? result.denied_actions : []).map(
      (entry: unknown): AgyDeniedAction => {
        const action = record(entry)
        return { action: string(action.action), display_name: string(action.display_name) }
      }
    )
  }
}

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

export const signedOut = (message: string): boolean =>
  /authenticat|sign in|not logged in|log in/i.test(message)

export const SIGN_IN_DETAIL = "Sign in to Antigravity to continue."
