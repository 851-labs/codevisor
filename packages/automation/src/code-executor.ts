/*
 * Codevisor's QuickJS bridge is adapted from @executor-js/runtime-quickjs and
 * @executor-js/codemode-core, originally published under the MIT License:
 *
 * Copyright (c) 2026 Rhys Sullivan
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in all
 * copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
 * SOFTWARE.
 */

import { getQuickJS, newQuickJSWASMModule } from "quickjs-emscripten"
import type {
  QuickJSContext,
  QuickJSDeferredPromise,
  QuickJSHandle,
  QuickJSRuntime
} from "quickjs-emscripten"
import { buildExecutionSource } from "./code-executor-source.js"

export interface CodeExecutionResult {
  readonly result: unknown
  readonly output?: ReadonlyArray<unknown>
  readonly error?: string
  readonly logs?: ReadonlyArray<string>
}

export interface CodeToolCall {
  readonly path: string
  readonly args: unknown
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

export interface ExecuteCodeOptions {
  readonly signal?: AbortSignal
}

export interface CodeExecutor {
  readonly execute: (
    code: string,
    toolInvoker: CodeToolInvoker,
    options?: ExecuteCodeOptions
  ) => Promise<CodeExecutionResult>
}

/** An intentional, user-safe tool failure that sandbox code is allowed to inspect. */
export class CodeExecutionToolError extends Error {
  override readonly name = "CodeExecutionToolError"
}

const DEFAULT_ACTIVE_TIMEOUT_MS = 30_000
const DEFAULT_MEMORY_LIMIT_BYTES = 64 * 1024 * 1024
const DEFAULT_MAX_STACK_SIZE_BYTES = 1024 * 1024
const EXECUTION_FILENAME = "codevisor-code-executor.js"

class ActiveExecutionBudget {
  private remainingMs: number
  private activeSince: number | undefined

  constructor(
    readonly limitMs: number,
    private readonly now: () => number
  ) {
    this.remainingMs = limitMs
  }

  exhausted(): boolean {
    if (this.remainingMs <= 0) return true
    return this.activeSince !== undefined && this.now() - this.activeSince >= this.remainingMs
  }

  run<A>(operation: () => A): A {
    if (this.exhausted()) throw new Error(timeoutMessage(this.limitMs))
    this.activeSince = this.now()
    try {
      return operation()
    } finally {
      this.remainingMs = Math.max(0, this.remainingMs - (this.now() - this.activeSince))
      this.activeSince = undefined
    }
  }
}

const timeoutMessage = (timeoutMs: number): string =>
  `QuickJS active execution timed out after ${timeoutMs}ms`

const cancellationMessage = (): string => "QuickJS execution was cancelled"

const toError = (cause: unknown): Error =>
  cause instanceof Error ? cause : new Error(String(cause))

const toErrorMessage = (cause: unknown): string => {
  if (typeof cause === "object" && cause !== null) {
    const message =
      "message" in cause && typeof cause.message === "string" ? cause.message : undefined
    if (message) return message
    const stack = "stack" in cause && typeof cause.stack === "string" ? cause.stack : undefined
    if (stack) return stack
  }
  const error = toError(cause)
  return error.stack ?? error.message
}

const normalizeExecutionError = (
  cause: unknown,
  budget: ActiveExecutionBudget,
  signal?: AbortSignal
): string => {
  if (signal?.aborted === true) return cancellationMessage()
  const message = toErrorMessage(cause)
  return budget.exhausted() && /\binterrupted\b/i.test(message)
    ? timeoutMessage(budget.limitMs)
    : message
}

const serializeJson = (value: unknown, label: string): string | undefined => {
  if (value === undefined) return undefined
  try {
    return JSON.stringify(value)
  } catch (cause) {
    throw new Error(`${label} is not JSON serializable: ${toError(cause).message}`)
  }
}

const readPropDump = (context: QuickJSContext, handle: QuickJSHandle, key: string): unknown => {
  const property = context.getProp(handle, key)
  try {
    return context.dump(property)
  } finally {
    property.dispose()
  }
}

const readOutputItems = (context: QuickJSContext): ReadonlyArray<unknown> | undefined => {
  const output = readPropDump(context, context.global, "__codevisor_outputs")
  return Array.isArray(output) && output.length > 0 ? output : undefined
}

const readResultState = (
  context: QuickJSContext,
  handle: QuickJSHandle
): { readonly settled: boolean; readonly value: unknown; readonly error: unknown } => ({
  settled: readPropDump(context, handle, "settled") === true,
  value: readPropDump(context, handle, "value"),
  error: readPropDump(context, handle, "error")
})

const createLogBridge = (context: QuickJSContext, logs: Array<string>): QuickJSHandle =>
  context.newFunction("__codevisor_log", (levelHandle, lineHandle) => {
    logs.push(`[${context.getString(levelHandle)}] ${context.getString(lineHandle)}`)
    return context.undefined
  })

const sandboxToolErrorMessage = (cause: unknown): string =>
  cause instanceof CodeExecutionToolError ? cause.message : "Internal tool error"

const createToolBridge = (
  context: QuickJSContext,
  toolInvoker: CodeToolInvoker,
  pendingDeferreds: Set<QuickJSDeferredPromise>
): QuickJSHandle =>
  context.newFunction("__codevisor_invokeTool", (pathHandle, argsHandle) => {
    const path = context.getString(pathHandle)
    const args =
      argsHandle === undefined || context.typeof(argsHandle) === "undefined"
        ? undefined
        : context.dump(argsHandle)
    const deferred = context.newPromise()
    pendingDeferreds.add(deferred)
    void deferred.settled.then(
      () => pendingDeferreds.delete(deferred),
      () => pendingDeferreds.delete(deferred)
    )
    void Promise.resolve()
      .then(() => toolInvoker.invoke({ path, args }))
      .then(
        (value) => {
          if (!deferred.alive) return
          try {
            const serialized = serializeJson(value, `Tool result for ${path}`)
            if (serialized === undefined) {
              deferred.resolve()
              return
            }
            const valueHandle = context.newString(serialized)
            deferred.resolve(valueHandle)
            valueHandle.dispose()
          } catch (cause) {
            const errorHandle = context.newError(toErrorMessage(cause))
            deferred.reject(errorHandle)
            errorHandle.dispose()
          }
        },
        (cause) => {
          if (!deferred.alive) return
          const errorHandle = context.newError(sandboxToolErrorMessage(cause))
          deferred.reject(errorHandle)
          errorHandle.dispose()
        }
      )
    return deferred.handle
  })

const drainJobs = (
  context: QuickJSContext,
  runtime: QuickJSRuntime,
  budget: ActiveExecutionBudget,
  signal?: AbortSignal
): void => {
  while (runtime.hasPendingJob()) {
    signal?.throwIfAborted()
    const pending = budget.run(() => runtime.executePendingJobs())
    if (pending.error !== undefined) {
      const error = context.dump(pending.error)
      pending.error.dispose()
      throw toError(error)
    }
  }
}

const waitForDeferred = async (
  pendingDeferreds: ReadonlySet<QuickJSDeferredPromise>,
  signal?: AbortSignal
): Promise<void> => {
  signal?.throwIfAborted()
  const settled = Promise.race([...pendingDeferreds].map((deferred) => deferred.settled))
  if (signal === undefined) return settled
  await new Promise<void>((resolve, reject) => {
    let finished = false
    const finish = (operation: () => void): void => {
      if (finished) return
      finished = true
      signal.removeEventListener("abort", onAbort)
      operation()
    }
    const onAbort = (): void =>
      finish(() => reject(signal.reason ?? new Error(cancellationMessage())))
    signal.addEventListener("abort", onAbort, { once: true })
    if (signal.aborted) onAbort()
    void settled.then(
      () => finish(resolve),
      (cause) => finish(() => reject(cause))
    )
  })
}

const drainAsync = async (
  context: QuickJSContext,
  runtime: QuickJSRuntime,
  pendingDeferreds: ReadonlySet<QuickJSDeferredPromise>,
  budget: ActiveExecutionBudget,
  signal?: AbortSignal
): Promise<void> => {
  drainJobs(context, runtime, budget, signal)
  while (pendingDeferreds.size > 0) {
    await waitForDeferred(pendingDeferreds, signal)
    drainJobs(context, runtime, budget, signal)
  }
  drainJobs(context, runtime, budget, signal)
}

const evaluate = async (
  executorOptions: CodeExecutorOptions,
  code: string,
  toolInvoker: CodeToolInvoker,
  executeOptions: ExecuteCodeOptions,
  sourceBuilder: (code: string) => string = buildExecutionSource,
  session?: { runtime: QuickJSRuntime; context: QuickJSContext }
): Promise<CodeExecutionResult> => {
  const activeTimeoutMs = Math.max(
    100,
    executorOptions.activeTimeoutMs ?? DEFAULT_ACTIVE_TIMEOUT_MS
  )
  const budget = new ActiveExecutionBudget(
    activeTimeoutMs,
    executorOptions.now ?? (() => performance.now())
  )
  const signal = executeOptions.signal
  const logs: Array<string> = []
  const pendingDeferreds = new Set<QuickJSDeferredPromise>()
  const QuickJS = await getQuickJS()
  const runtime = session?.runtime ?? QuickJS.newRuntime()
  try {
    runtime.setMemoryLimit(executorOptions.memoryLimitBytes ?? DEFAULT_MEMORY_LIMIT_BYTES)
    runtime.setMaxStackSize(executorOptions.maxStackSizeBytes ?? DEFAULT_MAX_STACK_SIZE_BYTES)
    runtime.setInterruptHandler(() => budget.exhausted() || signal?.aborted === true)
    const context = session?.context ?? runtime.newContext()
    try {
      signal?.throwIfAborted()
      const logBridge = createLogBridge(context, logs)
      context.setProp(context.global, "__codevisor_log", logBridge)
      logBridge.dispose()
      const toolBridge = createToolBridge(context, toolInvoker, pendingDeferreds)
      context.setProp(context.global, "__codevisor_invokeTool", toolBridge)
      toolBridge.dispose()

      const evaluated = budget.run(() => context.evalCode(sourceBuilder(code), EXECUTION_FILENAME))
      if (evaluated.error !== undefined) {
        const error = context.dump(evaluated.error)
        evaluated.error.dispose()
        return { result: null, error: normalizeExecutionError(error, budget, signal), logs }
      }
      context.setProp(context.global, "__codevisor_result", evaluated.value)
      evaluated.value.dispose()

      const stateResult = budget.run(() =>
        context.evalCode(
          "(function(p){ const state = { value: undefined, error: undefined, settled: false }; const formatError = (error) => { if (error && typeof error === 'object') { const message = typeof error.message === 'string' ? error.message : ''; const stack = typeof error.stack === 'string' ? error.stack : ''; if (message && stack) return stack.includes(message) ? stack : message + '\\n' + stack; if (message) return message; if (stack) return stack; } return String(error); }; p.then((value) => { state.value = value; state.settled = true; }, (error) => { state.error = formatError(error); state.settled = true; }); return state; })(__codevisor_result)"
        )
      )
      if (stateResult.error !== undefined) {
        const error = context.dump(stateResult.error)
        stateResult.error.dispose()
        return { result: null, error: normalizeExecutionError(error, budget, signal), logs }
      }
      const stateHandle = stateResult.value
      try {
        await drainAsync(context, runtime, pendingDeferreds, budget, signal)
        const state = readResultState(context, stateHandle)
        const output = readOutputItems(context)
        if (!state.settled) {
          return {
            result: null,
            error: timeoutMessage(activeTimeoutMs),
            ...(output === undefined ? {} : { output }),
            logs
          }
        }
        if (state.error !== undefined) {
          return {
            result: null,
            error: normalizeExecutionError(state.error, budget, signal),
            ...(output === undefined ? {} : { output }),
            logs
          }
        }
        return { result: state.value, ...(output === undefined ? {} : { output }), logs }
      } finally {
        stateHandle.dispose()
      }
    } finally {
      for (const deferred of pendingDeferreds) {
        if (deferred.alive) deferred.dispose()
      }
      pendingDeferreds.clear()
      if (session === undefined) context.dispose()
    }
  } catch (cause) {
    return { result: null, error: normalizeExecutionError(cause, budget, signal), logs }
  } finally {
    if (session === undefined) runtime.dispose()
  }
}

export const makeCodeExecutor = (options: CodeExecutorOptions = {}): CodeExecutor => ({
  execute: (code, toolInvoker, executeOptions = {}) =>
    evaluate(options, code, toolInvoker, executeOptions)
})

/** One isolated QuickJS realm per desktop session; cells are strictly ordered. */
export const makePersistentCodeExecutor = (
  sourceBuilder: (code: string) => string,
  options: CodeExecutorOptions = {}
): CodeExecutor & { close: () => Promise<void> } => {
  let session: { runtime: QuickJSRuntime; context: QuickJSContext } | undefined
  let tail: Promise<unknown> = Promise.resolve()
  let closed = false
  const dispose = () => {
    session?.context.dispose()
    session?.runtime.dispose()
    session = undefined
  }
  return {
    execute: (code, invoker, executeOptions = {}) => {
      const cell = tail.then(async () => {
        if (closed) return { result: null, error: "Computer Use REPL is closed" }
        if (session === undefined) {
          // The bundled Bellard engine leaks its context when large JSON tool
          // results are parsed after await. NG passes the screenshot stress test.
          const engine = await newQuickJSWASMModule(
            import("@jitl/quickjs-ng-wasmfile-release-sync")
          )
          const runtime = engine.newRuntime()
          session = { runtime, context: runtime.newContext() }
        }
        const result = await evaluate(
          options,
          code,
          invoker,
          executeOptions,
          sourceBuilder,
          session
        )
        if (
          executeOptions.signal?.aborted ||
          /QuickJS active execution timed out|out of memory/i.test(result.error ?? "")
        ) {
          dispose()
          return { ...result, error: `${result.error}. Computer Use bindings were reset.` }
        }
        return result
      })
      tail = cell.catch(() => undefined)
      return cell
    },
    close: async () => {
      closed = true
      await tail
      dispose()
    }
  }
}
