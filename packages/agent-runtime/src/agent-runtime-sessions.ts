import { Effect } from "effect"
import type { AgentRuntimeCore } from "./agent-runtime-core.js"
import type { AgentRuntimeService } from "./agent-runtime-types.js"
import { AgentRuntimeError, adapterPromise } from "./types.js"

export type AgentSessionOperations = Pick<
  AgentRuntimeService,
  | "answerQuestion"
  | "authenticateHarness"
  | "cancel"
  | "clearGoal"
  | "closeAgentSession"
  | "logoutHarness"
  | "probeHarnessAuth"
  | "prompt"
  | "setConfigOption"
  | "setGoal"
  | "setMode"
>

/// Operations on an already-loaded session (prompting, cancelling, config,
/// goals, questions) plus the harness auth pass-throughs.
export const makeAgentSessionOperations = (core: AgentRuntimeCore): AgentSessionOperations => {
  const { definitionFor, sessionFor, sessions, withSessionLifecycle } = core

  return {
    prompt: (sessionId, input) =>
      Effect.gen(function* () {
        const session = yield* sessionFor(sessionId)
        return yield* session.handle.prompt(input)
      }),
    cancel: (sessionId) =>
      adapterPromise("cancel", () =>
        withSessionLifecycle(sessionId, async () => {
          const session = sessions.get(sessionId)
          if (session === undefined) {
            throw new Error(`Agent session is not loaded: ${sessionId}`)
          }
          const result = await Effect.runPromise(session.handle.cancel)
          await session.chain
          if (result.runtimeState !== "retire" || sessions.get(sessionId) !== session) {
            return result
          }
          let closeFailure: unknown
          try {
            await Effect.runPromise(session.handle.close)
          } catch (cause) {
            closeFailure = cause
          } finally {
            await session.chain
            // Matching-handle check prevents stale cancellation cleanup from
            // deleting a replacement installed by another lifecycle path.
            if (sessions.get(sessionId) === session) {
              sessions.delete(sessionId)
            }
          }
          if (closeFailure !== undefined) throw closeFailure
          return result
        })
      ),
    closeAgentSession: (sessionId) =>
      adapterPromise("closeAgentSession", () =>
        withSessionLifecycle(sessionId, async () => {
          const session = sessions.get(sessionId)
          if (session === undefined) return
          let closeFailure: unknown
          try {
            await Effect.runPromise(session.handle.close)
          } catch (cause) {
            closeFailure = cause
          } finally {
            await session.chain
            if (sessions.get(sessionId) === session) {
              sessions.delete(sessionId)
            }
          }
          if (closeFailure !== undefined) throw closeFailure
        })
      ),
    setMode: (sessionId, modeId) =>
      Effect.gen(function* () {
        const session = yield* sessionFor(sessionId)
        return yield* session.handle.setMode(modeId)
      }),
    setConfigOption: (sessionId, configId, value) =>
      Effect.gen(function* () {
        const session = yield* sessionFor(sessionId)
        return yield* session.handle.setConfigOption(configId, value)
      }),
    setGoal: (sessionId, update) =>
      Effect.gen(function* () {
        const session = yield* sessionFor(sessionId)
        const setGoal = session.handle.setGoal
        if (setGoal === undefined) {
          return yield* Effect.fail(
            new AgentRuntimeError({
              operation: "setGoal",
              message: "Goals are not supported by this harness"
            })
          )
        }
        return yield* setGoal(update)
      }),
    clearGoal: (sessionId) =>
      Effect.gen(function* () {
        const session = yield* sessionFor(sessionId)
        const clearGoal = session.handle.clearGoal
        if (clearGoal === undefined) {
          return yield* Effect.fail(
            new AgentRuntimeError({
              operation: "clearGoal",
              message: "Goals are not supported by this harness"
            })
          )
        }
        return yield* clearGoal
      }),
    answerQuestion: (sessionId, questionId, answer) =>
      Effect.gen(function* () {
        const session = yield* sessionFor(sessionId)
        const answerQuestion = session.handle.answerQuestion
        if (answerQuestion === undefined) {
          return yield* Effect.fail(
            new AgentRuntimeError({
              operation: "answerQuestion",
              message: "Questions are not supported by this harness"
            })
          )
        }
        return yield* answerQuestion(questionId, answer)
      }),
    probeHarnessAuth: (harnessId, account) =>
      Effect.gen(function* () {
        const { definition, provider } = yield* definitionFor(harnessId)
        if (provider.probeAuth === undefined) {
          return { state: "notRequired" as const, methods: [], canLogout: false }
        }
        return yield* provider.probeAuth(definition, account)
      }),
    authenticateHarness: (harnessId, methodId, account) =>
      Effect.gen(function* () {
        const { definition, provider } = yield* definitionFor(harnessId)
        if (provider.authenticate === undefined) {
          return yield* Effect.fail(
            new AgentRuntimeError({
              operation: "authenticate",
              message: "Authentication is not supported by this harness"
            })
          )
        }
        return yield* provider.authenticate(definition, methodId, account)
      }),
    logoutHarness: (harnessId, account) =>
      Effect.gen(function* () {
        const { definition, provider } = yield* definitionFor(harnessId)
        if (provider.logout === undefined) {
          return yield* Effect.fail(
            new AgentRuntimeError({
              operation: "logout",
              message: "Logout is not supported by this harness"
            })
          )
        }
        return yield* provider.logout(definition, account)
      })
  }
}
