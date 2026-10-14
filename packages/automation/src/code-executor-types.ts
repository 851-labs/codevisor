export interface CodeExecutionResult {
  readonly result: unknown
  readonly output?: ReadonlyArray<unknown>
  readonly error?: string
  readonly logs?: ReadonlyArray<string>
}

export interface CodeToolTarget {
  readonly machine?: string
  readonly machineName?: string
  readonly internal?: true
}

export interface CodeToolCall {
  readonly path: string
  readonly args: unknown
  readonly target?: CodeToolTarget
}

export interface CodeToolInvoker {
  readonly invoke: (call: CodeToolCall) => Promise<unknown>
}

export interface CodeExecutorOptions {
  readonly activeTimeoutMs?: number
  readonly now?: () => number
  readonly memoryLimitBytes?: number
  readonly maxStackSizeBytes?: number
}

export interface CodeExecutionContext {
  readonly machine?: { readonly id: string; readonly name: string }
  readonly originClientId?: string
}

export interface ExecuteCodeOptions {
  readonly signal?: AbortSignal
  readonly onStatus?: (text: string) => void
  readonly context?: CodeExecutionContext
}

export interface CodeExecutor {
  readonly execute: (
    code: string,
    toolInvoker: CodeToolInvoker,
    options?: ExecuteCodeOptions
  ) => Promise<CodeExecutionResult>
}

export interface CodeExecutionToolErrorOptions {
  readonly code?: string
  readonly details?: Readonly<Record<string, unknown>>
}

export class CodeExecutionToolError extends Error {
  override readonly name = "CodeExecutionToolError"
  readonly code?: string
  readonly details?: Readonly<Record<string, unknown>>

  constructor(message: string, options: CodeExecutionToolErrorOptions = {}) {
    super(message)
    if (options.code !== undefined) this.code = options.code
    if (options.details !== undefined) this.details = options.details
  }
}
