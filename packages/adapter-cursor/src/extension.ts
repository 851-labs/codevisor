import * as acp from "@agentclientprotocol/sdk"
import {
  normalizeAcpConfigOptions,
  runtimeEventFromNotification,
  type AcpAgentConnection,
  type AcpConnectionExtensionContext,
  type AcpStdioExtensionFactory
} from "@codevisor/adapter-acp"
import type { RuntimeEvent } from "@codevisor/agent-runtime"
import { Effect } from "effect"
import {
  cursorClientCapabilities,
  cursorConfigSelection,
  cursorSessionMetadata,
  normalizeCursorConfigOptions
} from "./config.js"
import {
  CursorTodoTracker,
  cursorAskQuestion,
  cursorCreatePlanQuestion,
  cursorGenerateImageEvent,
  cursorTaskEvent,
  type CursorAskQuestionResponse,
  type CursorCreatePlanResponse
} from "./cursor.js"
import { CursorStreamNormalizer } from "./stream.js"

export const CURSOR_MAX_TRANSIENT_RETRIES = 3
const CURSOR_RECOVERY_BACKOFF_BASE_MS = 1000
const CURSOR_RECOVERY_BACKOFF_CAP_MS = 8000
const CURSOR_CONTINUE_PROMPT = "Please continue."

export const cursorRecoveryBackoffMs = (retryIndex: number): number =>
  Math.min(CURSOR_RECOVERY_BACKOFF_BASE_MS * 2 ** retryIndex, CURSOR_RECOVERY_BACKOFF_CAP_MS)

interface CursorRecoveryWait {
  readonly timer: ReturnType<typeof setTimeout>
  readonly resolve: (proceed: boolean) => void
}

interface CursorRecoveryTurn {
  cancelled: boolean
  wait: CursorRecoveryWait | undefined
}

class CursorRecoveryController {
  private readonly turns = new Map<string, CursorRecoveryTurn>()

  begin(sessionId: string): void {
    this.finish(sessionId)
    this.turns.set(sessionId, { cancelled: false, wait: undefined })
  }

  isCancelled(sessionId: string): boolean {
    return this.turns.get(sessionId)?.cancelled === true
  }

  wait(sessionId: string, delayMs: number): Promise<boolean> {
    const turn = this.turns.get(sessionId)
    if (turn === undefined || turn.cancelled) return Promise.resolve(false)
    return new Promise((resolve) => {
      const timer = setTimeout(() => {
        if (turn.wait?.timer !== timer) return
        turn.wait = undefined
        resolve(!turn.cancelled)
      }, delayMs)
      turn.wait = { resolve, timer }
    })
  }

  cancel(sessionId: string): void {
    const turn = this.turns.get(sessionId)
    if (turn === undefined) return
    turn.cancelled = true
    this.releaseWait(turn)
  }

  finish(sessionId: string): void {
    const turn = this.turns.get(sessionId)
    if (turn === undefined) return
    this.releaseWait(turn)
    this.turns.delete(sessionId)
  }

  cancelAll(): void {
    for (const sessionId of this.turns.keys()) this.cancel(sessionId)
  }

  private releaseWait(turn: CursorRecoveryTurn): void {
    const wait = turn.wait
    if (wait === undefined) return
    turn.wait = undefined
    clearTimeout(wait.timer)
    wait.resolve(false)
  }
}

const emitAll = (
  emit: (event: RuntimeEvent) => void,
  events: ReadonlyArray<RuntimeEvent>
): void => {
  for (const event of events) emit(event)
}

const extendCursorConnection = (
  base: AcpAgentConnection,
  _context: AcpConnectionExtensionContext,
  emit: (event: RuntimeEvent) => void,
  normalizer: CursorStreamNormalizer,
  recovery: CursorRecoveryController
): AcpAgentConnection => {
  const prompt = (sessionId: string, input: Parameters<AcpAgentConnection["prompt"]>[1]) =>
    Effect.gen(function* () {
      recovery.begin(sessionId)
      emitAll(emit, normalizer.startPrompt(sessionId))
      let promptInput = input
      let transientRetries = 0

      while (true) {
        const result = yield* base
          .prompt(sessionId, promptInput)
          .pipe(Effect.tapError(() => Effect.sync(() => normalizer.cancelTurn(sessionId))))
        if (result.stopReason === "cancelled" || recovery.isCancelled(sessionId)) {
          normalizer.cancelTurn(sessionId)
          return { stopReason: "cancelled" }
        }

        const leg = normalizer.settlePromptLeg(sessionId)
        emitAll(emit, leg.events)
        const terminalError = leg.terminalError
        if (terminalError === undefined) {
          emitAll(emit, normalizer.completeTurn(sessionId))
          return result
        }
        if (terminalError.kind === "cancelled") {
          normalizer.cancelTurn(sessionId)
          return { stopReason: "cancelled" }
        }
        if (terminalError.kind !== "retriable") {
          emitAll(emit, normalizer.completeTurn(sessionId))
          return { stopDetail: terminalError.message, stopReason: "end_turn" }
        }
        if (transientRetries >= CURSOR_MAX_TRANSIENT_RETRIES) {
          emitAll(emit, normalizer.completeTurn(sessionId))
          return {
            retryable: true,
            stopDetail: terminalError.message,
            stopReason: "end_turn"
          }
        }

        transientRetries += 1
        emit({
          kind: "session.updated",
          payload: {
            retrying: {
              attempt: transientRetries,
              message: "Cursor is unavailable, restarting response",
              of: CURSOR_MAX_TRANSIENT_RETRIES
            }
          },
          subjectId: sessionId
        })
        const proceed = yield* Effect.promise(() =>
          recovery.wait(sessionId, cursorRecoveryBackoffMs(transientRetries - 1))
        )
        if (!proceed) {
          normalizer.cancelTurn(sessionId)
          return { stopReason: "cancelled" }
        }
        normalizer.continuePrompt(sessionId)
        promptInput = CURSOR_CONTINUE_PROMPT
      }
    }).pipe(Effect.ensuring(Effect.sync(() => recovery.finish(sessionId))))

  return {
    ...base,
    prompt,
    cancel: (sessionId) =>
      Effect.gen(function* () {
        recovery.cancel(sessionId)
        normalizer.cancelTurn(sessionId)
        return yield* base.cancel(sessionId)
      }),
    close: Effect.gen(function* () {
      recovery.cancelAll()
      return yield* base.close
    })
  }
}

export const makeCursorExtension: AcpStdioExtensionFactory = ({ emit, enqueueQuestion }) => {
  const normalizer = new CursorStreamNormalizer()
  const recovery = new CursorRecoveryController()
  const todos = new CursorTodoTracker()
  let activeSessionId: string | undefined

  const withSession = <T>(map: (sessionId: string) => T | undefined): T | undefined =>
    activeSessionId === undefined ? undefined : map(activeSessionId)

  return {
    customizeClientCapabilities: cursorClientCapabilities,
    configureClientApp: (app) => {
      app.onRequest<unknown, CursorAskQuestionResponse>(
        "cursor/ask_question",
        (params) => params,
        ({ params }) => {
          const question = withSession((sessionId) => cursorAskQuestion(params, sessionId))
          return question === undefined
            ? Promise.resolve({ outcome: { outcome: "cancelled" as const } })
            : enqueueQuestion(question)
        }
      )
      app.onRequest<unknown, CursorCreatePlanResponse>(
        "cursor/create_plan",
        (params) => params,
        ({ params }) => {
          const question = withSession((sessionId) => {
            const plan = todos.update(sessionId, params)
            if (plan !== undefined) emit(plan)
            return cursorCreatePlanQuestion(params, sessionId)
          })
          return question === undefined
            ? Promise.resolve({ outcome: { outcome: "cancelled" as const } })
            : enqueueQuestion(question)
        }
      )

      const extensionNotification = (
        method: string,
        map: (params: unknown, sessionId: string) => RuntimeEvent | undefined
      ): void => {
        const handle = (params: unknown): void => {
          const event = withSession((sessionId) => map(params, sessionId))
          if (event !== undefined) emit(event)
        }
        // Cursor 2026.07 sends these through `extMethod` (a request whose
        // response it ignores), while the public contract calls them
        // notifications. Accept both forms so either transport is lossless.
        app.onRequest<unknown, Record<string, never>>(
          method,
          (params) => params,
          ({ params }) => {
            handle(params)
            return {}
          }
        )
        app.onNotification<unknown>(
          method,
          (params) => params,
          ({ params }) => handle(params)
        )
      }

      extensionNotification("cursor/update_todos", (params, sessionId) =>
        todos.update(sessionId, params)
      )
      extensionNotification("cursor/task", cursorTaskEvent)
      extensionNotification("cursor/generate_image", cursorGenerateImageEvent)
      return app
    },
    mapSessionNotification: (notification) => {
      const update = notification.update as unknown as Record<string, unknown>
      if (update.sessionUpdate !== "config_option_update" || !Array.isArray(update.configOptions)) {
        return normalizer.mapSessionNotification(notification)
      }
      const normalized = {
        ...notification,
        update: {
          ...update,
          configOptions: normalizeCursorConfigOptions(
            normalizeAcpConfigOptions(update.configOptions as never)
          )
        }
      } as unknown as acp.SessionNotification
      return [runtimeEventFromNotification(normalized)]
    },
    sdkConnectionCustomization: {
      customizeSessionMetadata: (sessionId, _response, metadata) => {
        activeSessionId = sessionId
        // `session/load` replays notifications before returning its metadata;
        // this closes the final historical turn when no following user echo
        // exists to provide that boundary.
        emitAll(emit, normalizer.completeTurn(sessionId))
        return cursorSessionMetadata(metadata)
      },
      setConfigOption: async ({ connection, sessionId, configId, value }) => {
        if (configId !== "speed") return undefined
        const selection = cursorConfigSelection(configId, value)
        const response = await connection.agent.request(acp.methods.agent.session.setConfigOption, {
          configId: selection.configId,
          sessionId,
          value: selection.value
        })
        return normalizeCursorConfigOptions(normalizeAcpConfigOptions(response.configOptions ?? []))
      },
      extendConnection: (connection, context) =>
        extendCursorConnection(connection, context, emit, normalizer, recovery)
    }
  }
}
