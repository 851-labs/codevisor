import * as acp from "@agentclientprotocol/sdk"
import {
  normalizeAcpConfigOptions,
  runtimeEventFromNotification,
  type AcpAgentConnection,
  type AcpConnectionExtensionContext,
  type AcpPromptResult,
  type AcpStdioExtensionFactory
} from "@codevisor/adapter-acp"
import { harnessFailureStop, usageLimitStop, type RuntimeEvent } from "@codevisor/agent-runtime"
import { isPlainRecord } from "@codevisor/api"
import type { SessionConfigOption } from "@codevisor/api"
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
  type CursorAskQuestionResponse,
  type CursorCreatePlanResponse
} from "./cursor.js"
import type { CursorTerminalError } from "./errors.js"
import { record } from "./internal.js"
import { CursorStreamNormalizer } from "./stream.js"
import {
  CURSOR_SUBAGENT_METHOD,
  CursorSubagents,
  rerouteCursorSubagentAnnouncement
} from "./subagents.js"

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

const endsTurn = (error: CursorTerminalError, transientRetries: number): boolean =>
  error.kind !== "retriable" || transientRetries >= CURSOR_MAX_TRANSIENT_RETRIES

const terminalStop = (error: CursorTerminalError): AcpPromptResult => {
  if (error.kind === "usage_limit") {
    return { stopReason: "end_turn", ...usageLimitStop(error.message) }
  }
  if (error.kind === "auth_required") return { stopReason: "end_turn", stopKind: "authRequired" }
  if (error.kind === "retriable") {
    return {
      retryable: true,
      stopDetail: error.message,
      stopKind: "harnessFailed",
      stopReason: "end_turn"
    }
  }
  return { stopReason: "end_turn", ...harnessFailureStop({ message: error.message }) }
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
        if (endsTurn(terminalError, transientRetries)) {
          emitAll(emit, normalizer.completeTurn(sessionId))
          return terminalStop(terminalError)
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

const rerouteSubagentLine = (line: string): string => {
  try {
    const message: unknown = JSON.parse(line)
    if (!isPlainRecord(message)) return line
    const rerouted = rerouteCursorSubagentAnnouncement(message)
    return rerouted === message ? line : JSON.stringify(rerouted)
  } catch {
    return line
  }
}

export const makeCursorExtension: AcpStdioExtensionFactory = ({ emit, enqueueQuestion }) => {
  const normalizer = new CursorStreamNormalizer()
  const recovery = new CursorRecoveryController()
  const todos = new CursorTodoTracker()
  const subagents = new CursorSubagents()
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
          if (question === undefined) {
            return Promise.resolve({ outcome: { outcome: "cancelled" as const } })
          }
          return enqueueQuestion(question)
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
          if (question === undefined) {
            return Promise.resolve({ outcome: { outcome: "cancelled" as const } })
          }
          return enqueueQuestion(question)
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
      extensionNotification("cursor/task", (params, sessionId) =>
        subagents.taskEvent(params, sessionId)
      )
      app.onNotification<unknown>(
        CURSOR_SUBAGENT_METHOD,
        (params) => params,
        ({ params }) => emitAll(emit, subagents.announcement(params))
      )
      extensionNotification("cursor/generate_image", cursorGenerateImageEvent)
      return app
    },
    rewriteAgentLine: (line) => (line.includes('"subagent_') ? rerouteSubagentLine(line) : line),
    mapSessionNotification: (notification) => {
      const { sessionId, update } = notification
      const normalized = (): ReadonlyArray<RuntimeEvent> =>
        subagents.mapToolEvents(sessionId, normalizer.mapSessionNotification(notification))
      if (subagents.isChildSession(sessionId)) {
        if (subagents.isThreadUpdate(update)) return subagents.childEvents(sessionId, normalized())
        return []
      }
      if (update.sessionUpdate !== "config_option_update" || !Array.isArray(update.configOptions)) {
        return normalized()
      }
      const event = runtimeEventFromNotification(notification)
      const payload = record(event.payload)
      if (payload === undefined || !Array.isArray(payload.configOptions)) return [event]
      return [
        {
          ...event,
          payload: {
            ...payload,
            configOptions: normalizeCursorConfigOptions(
              payload.configOptions as ReadonlyArray<SessionConfigOption>
            )
          }
        }
      ]
    },
    sdkConnectionCustomization: {
      customizeSessionMetadata: (sessionId, _response, metadata) => {
        activeSessionId = sessionId
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
