/// The code executor's public contract: tool calls from sandbox code, the
/// options an execution accepts, and the intentional tool error type.

export interface CodeExecutionResult {
  readonly result: unknown
  readonly output?: ReadonlyArray<unknown>
  readonly error?: string
  readonly logs?: ReadonlyArray<string>
}

/** Where a sandbox tool call should run. Absent means the current machine. */
export interface CodeToolTarget {
  /** Machine id the call is routed to. */
  readonly machine?: string
  /** Display name of that machine, for transcripts and error messages. */
  readonly machineName?: string
  /** A lookup the prelude makes on the script's behalf, not one it wrote. */
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
  /** Maximum time spent actively executing code inside QuickJS. Host tool waits are excluded. */
  readonly activeTimeoutMs?: number
  /** Monotonic clock used to account for active execution. */
  readonly now?: () => number
  readonly memoryLimitBytes?: number
  readonly maxStackSizeBytes?: number
}

/** Facts the sandbox exposes as `machines.current` and client `isOrigin`. */
export interface CodeExecutionContext {
  readonly machine?: { readonly id: string; readonly name: string }
  /** The client window that sent the current turn's prompt, when known. */
  readonly originClientId?: string
}

export interface ExecuteCodeOptions {
  readonly signal?: AbortSignal
  /** Receives each `status(text)` call from sandbox code. */
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
  /** Machine-readable failure kind. The sandbox maps `machine_unavailable`
   *  and `client_unavailable` to MachineUnavailableError and
   *  ClientUnavailableError. */
  readonly code?: string
  readonly details?: Readonly<Record<string, unknown>>
}

/** An intentional, user-safe tool failure that sandbox code is allowed to inspect. */
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
