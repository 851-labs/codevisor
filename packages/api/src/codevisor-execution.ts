import { isRecord } from "./records.js"

export type CodevisorExecutionIcon =
  | { readonly kind: "site"; readonly origin: string }
  | {
      readonly kind: "mcp"
      readonly serverId: string
      readonly host?: string
    }
  | {
      readonly kind: "app"
      readonly bundleId: string
      readonly name?: string
      readonly path?: string
    }
  | { readonly kind: "builtin"; readonly id: "browser" | "computer" | "codevisor" | "plugin" }

export interface CodevisorExecutionFile {
  readonly fileId: string
  readonly name?: string
  readonly mimeType?: string
}

export interface CodevisorExecutionCall {
  readonly path: string
  readonly title?: string
  readonly icon?: CodevisorExecutionIcon
  readonly files?: ReadonlyArray<CodevisorExecutionFile>
  readonly machine?: string
  readonly ok: boolean
  readonly ms: number
  readonly error?: string
}

export interface CodevisorExecutionState {
  readonly state: "running" | "completed" | "failed"
  readonly description?: string
  readonly status?: string
  readonly calls: ReadonlyArray<CodevisorExecutionCall>
  readonly error?: string
  readonly icon?: CodevisorExecutionIcon
  readonly activeIcon?: CodevisorExecutionIcon
}

export interface CodevisorSkillRead {
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
  if (isRecord(value)) {
    // oxlint-disable-next-line unicorn/no-array-sort
    const keys = Object.keys(value).sort()
    return Object.fromEntries(keys.map((key) => [key, canonicalize(value[key])]))
  }
  return value
}

export const canonicalExecutionArgs = (args: unknown): string =>
  JSON.stringify(canonicalize(args)) ?? "null"
