import type * as acp from "@agentclientprotocol/sdk"
import type { AcpAgentConnection } from "@codevisor/adapter-acp"
import type { PromptInput, RuntimeEvent } from "@codevisor/agent-runtime"
import { Effect } from "effect"
import { afterEach, describe, expect, it, vi } from "vitest"
import { CURSOR_MAX_TRANSIENT_RETRIES, makeCursorExtension } from "./extension.js"

const SESSION_ID = "cursor-session"
const CONTINUE_PROMPT = "Please continue."

type PromptScript = (emitNotification: (update: Record<string, unknown>) => void) => void

class FakeCursorConnection implements AcpAgentConnection {
  readonly prompts: Array<string | PromptInput> = []
  readonly cancellations: Array<string> = []

  constructor(private readonly scripts: Array<PromptScript>) {}

  createSession(cwd: string) {
    return Effect.succeed({ configOptions: [], cwd, sessionId: SESSION_ID })
  }

  loadSession(sessionId: string) {
    return Effect.succeed({ configOptions: [], sessionId })
  }

  prompt(sessionId: string, input: string | PromptInput) {
    return Effect.sync(() => {
      this.prompts.push(input)
      const script = this.scripts.shift()
      if (script === undefined) throw new Error("Unexpected Cursor prompt")
      script((update) => this.emitNotification(sessionId, update))
      return { stopReason: "end_turn" }
    })
  }

  cancel(sessionId: string) {
    return Effect.sync(() => {
      this.cancellations.push(sessionId)
    })
  }

  setMode() {
    return Effect.void
  }

  setConfigOption() {
    return Effect.succeed([])
  }

  probeAuth() {
    return Effect.succeed({
      canLogout: false as const,
      methods: [] as const,
      state: "notRequired" as const
    })
  }

  authenticate() {
    return Effect.void
  }

  readonly logout = Effect.void
  readonly close = Effect.void

  emitNotification: (sessionId: string, update: Record<string, unknown>) => void = () => {
    throw new Error("Notification mapper was not installed")
  }
}

const userChunk = (text: string): Record<string, unknown> => ({
  content: { text, type: "text" },
  sessionUpdate: "user_message_chunk"
})

const agentChunk = (text: string): Record<string, unknown> => ({
  content: { text, type: "text" },
  sessionUpdate: "agent_message_chunk"
})

const retriableError = (): Record<string, unknown> =>
  agentChunk("\n\nError: RetriableError: [unavailable] Error")

const makeHarness = (scripts: Array<PromptScript>) => {
  const events: Array<RuntimeEvent> = []
  const extension = makeCursorExtension({
    emit: (event) => events.push(event),
    enqueueQuestion: <Response>() =>
      Promise.reject(new Error("Unexpected Cursor question")) as Promise<Response>
  })
  const base = new FakeCursorConnection(scripts)
  base.emitNotification = (sessionId, update) => {
    const notification = { sessionId, update } as unknown as acp.SessionNotification
    const mapped = extension.mapSessionNotification?.(notification) ?? []
    events.push(...mapped)
  }
  const connection = extension.sdkConnectionCustomization?.extendConnection?.(base, {
    connection: {} as acp.ClientConnection
  })
  if (connection === undefined) throw new Error("Cursor connection extension was not installed")
  return { base, connection, events }
}

const retryEvents = (events: ReadonlyArray<RuntimeEvent>): Array<Record<string, unknown>> =>
  events
    .map((event) => event.payload as Record<string, unknown>)
    .filter((payload) => payload.retrying !== undefined)

const outputText = (events: ReadonlyArray<RuntimeEvent>): string =>
  events
    .filter((event) => event.kind === "session.output")
    .map((event) => {
      const payload = event.payload as Record<string, unknown>
      const content = payload.content as Record<string, unknown> | undefined
      return typeof content?.text === "string" ? content.text : ""
    })
    .join("")

afterEach(() => {
  vi.useRealTimers()
})

describe("Cursor ACP recovery", () => {
  it("continues the same session after a retriable terminal error", async () => {
    vi.useFakeTimers()
    const { base, connection, events } = makeHarness([
      (emit) => {
        emit(userChunk("Summarize the repository"))
        emit(agentChunk("Initial answer. "))
        emit(agentChunk("\n\nError: Retriable"))
        emit(agentChunk("Error: [unavailable] Error"))
      },
      (emit) => {
        emit(userChunk(CONTINUE_PROMPT))
        emit(agentChunk("Recovered answer"))
      }
    ])

    const pending = Effect.runPromise(connection.prompt(SESSION_ID, "Summarize the repository"))
    await vi.runAllTimersAsync()

    await expect(pending).resolves.toEqual({ stopReason: "end_turn" })
    expect(base.prompts).toEqual(["Summarize the repository", CONTINUE_PROMPT])
    expect(retryEvents(events)).toEqual([
      expect.objectContaining({
        retrying: {
          attempt: 1,
          message: "Cursor is unavailable, restarting response",
          of: CURSOR_MAX_TRANSIENT_RETRIES
        }
      })
    ])
    const responseChunks = events
      .filter((event) => {
        const payload = event.payload as Record<string, unknown>
        const content = payload.content as Record<string, unknown> | undefined
        return event.kind === "session.output" && typeof content?.text === "string"
      })
      .map((event) => event.payload as Record<string, unknown>)
    expect(responseChunks.map((payload) => payload.messageId)).toEqual([
      "cursor:cursor-session:0:0",
      "cursor:cursor-session:0:0",
      "cursor:cursor-session:0:0"
    ])
    expect(outputText(events)).toBe("Initial answer. Recovered answer")
  })

  it("surfaces a retryable turn failure only after bounded retries are exhausted", async () => {
    vi.useFakeTimers()
    const scripts = Array.from(
      { length: CURSOR_MAX_TRANSIENT_RETRIES + 1 },
      () =>
        ((emit) => {
          emit(retriableError())
        }) satisfies PromptScript
    )
    const { base, connection, events } = makeHarness(scripts)

    const pending = Effect.runPromise(connection.prompt(SESSION_ID, "Do the work"))
    await vi.runAllTimersAsync()

    await expect(pending).resolves.toEqual({
      retryable: true,
      stopDetail: "Cursor is temporarily unavailable.",
      stopReason: "end_turn"
    })
    expect(base.prompts).toEqual(["Do the work", CONTINUE_PROMPT, CONTINUE_PROMPT, CONTINUE_PROMPT])
    expect(retryEvents(events)).toHaveLength(CURSOR_MAX_TRANSIENT_RETRIES)
    expect(outputText(events)).toBe("")
  })

  it("cancels a pending recovery without sending a continuation prompt", async () => {
    vi.useFakeTimers()
    const { base, connection } = makeHarness([
      (emit) => emit(retriableError()),
      () => {
        throw new Error("Recovery prompt should have been cancelled")
      }
    ])

    const pending = Effect.runPromise(connection.prompt(SESSION_ID, "Do the work"))
    await vi.advanceTimersByTimeAsync(0)
    await Effect.runPromise(connection.cancel(SESSION_ID))

    await expect(pending).resolves.toEqual({ stopReason: "cancelled" })
    expect(base.prompts).toEqual(["Do the work"])
    expect(base.cancellations).toEqual([SESSION_ID])
  })

  it("does not retry a non-retriable Cursor terminal error", async () => {
    const { base, connection, events } = makeHarness([
      (emit) => emit(agentChunk("Error: NonRetriableError: Authentication failed"))
    ])

    await expect(Effect.runPromise(connection.prompt(SESSION_ID, "Do the work"))).resolves.toEqual({
      stopDetail: "Authentication failed",
      stopReason: "end_turn"
    })
    expect(base.prompts).toEqual(["Do the work"])
    expect(retryEvents(events)).toEqual([])
    expect(outputText(events)).toBe("")
  })
})
