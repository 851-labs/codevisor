import type { QuestionResolvedPayload, QuestionSpec } from "@codevisor/api"
import type { QuestionAnswer, RuntimeEventSink } from "@codevisor/agent-runtime"
import type { CodevisorDatabaseService } from "@codevisor/db"
import { randomUUID } from "node:crypto"
import { Effect } from "effect"
import type { BrowserBackend, BrowserUseProvider } from "./browser-use-provider.js"

interface PendingQuestion {
  readonly sessionId: string
  readonly questions: ReadonlyArray<QuestionSpec>
  readonly resolve: (answer: QuestionAnswer) => void
}

interface AskedQuestion {
  readonly questionId: string
  readonly answer: Promise<QuestionAnswer>
}

type BrowserChoice = BrowserBackend | "back"

export interface BrowserSetupBroker {
  readonly setSink: (sessionId: string, sink: RuntimeEventSink) => void
  readonly resolveBackend: (
    sessionId: string,
    requested?: BrowserBackend
  ) => Promise<BrowserBackend>
  readonly answerQuestion: (
    sessionId: string,
    questionId: string,
    answer: QuestionAnswer
  ) => Promise<boolean>
  readonly closeSession: (sessionId: string) => Promise<void>
  readonly close: () => Promise<void>
}

const run = <A>(effect: Effect.Effect<A, unknown>): Promise<A> => Effect.runPromise(effect)

const selectedAnswer = (
  answer: QuestionAnswer
): { readonly label?: string; readonly note?: string } => {
  if (answer.outcome !== "answered") return {}
  const entry = answer.answers?.browser_preference
  const label = entry?.answers[0]
  const note = entry?.note?.trim()
  return {
    ...(label === undefined ? {} : { label }),
    ...(note === undefined || note === "" ? {} : { note })
  }
}

const rejection = (answer: QuestionAnswer): Error => {
  const note = selectedAnswer(answer).note
  return new Error(
    note === undefined ? "The user rejected Browser Use." : `The user rejected Browser Use: ${note}`
  )
}

export const makeBrowserSetupBroker = (
  db: CodevisorDatabaseService,
  provider: BrowserUseProvider
): BrowserSetupBroker => {
  const sinks = new Map<string, RuntimeEventSink>()
  const pending = new Map<string, PendingQuestion>()
  const active = new Map<string, Promise<BrowserBackend>>()

  const emit = async (sessionId: string, payload: unknown): Promise<void> => {
    const sink = sinks.get(sessionId)
    if (sink === undefined) throw new Error("Browser setup requires an active Codevisor session")
    await sink({ kind: "session.output", subjectId: sessionId, payload })
  }

  const ask = async (
    sessionId: string,
    question: QuestionSpec,
    message?: string
  ): Promise<AskedQuestion> => {
    const questionId = `browser-setup:${randomUUID()}`
    const questions = [question]
    const answer = new Promise<QuestionAnswer>((resolve) => {
      pending.set(questionId, { sessionId, questions, resolve })
    })
    try {
      await emit(sessionId, {
        questionId,
        questions,
        sessionUpdate: "question",
        ...(message === undefined ? {} : { message })
      })
    } catch (cause) {
      pending.delete(questionId)
      throw cause
    }
    return { questionId, answer }
  }

  const resolveAutomatically = async (questionId: string): Promise<boolean> => {
    const current = pending.get(questionId)
    if (current === undefined) return false
    pending.delete(questionId)
    const resolved: QuestionResolvedPayload = {
      outcome: "autoResolved",
      questionId,
      questions: current.questions,
      sessionUpdate: "question_resolved"
    }
    await emit(current.sessionId, resolved)
    current.resolve({
      outcome: "answered",
      answers: { browser_preference: { answers: ["Use Google Chrome"] } }
    })
    return true
  }

  const remember = async (backend: BrowserBackend): Promise<BrowserBackend> => {
    await run(db.setBrowserPreference(backend === "extension" ? "chrome" : "managed"))
    return backend
  }

  const waitForConnectionOrAnswer = async (
    asked: AskedQuestion
  ): Promise<"connected" | QuestionAnswer> => {
    if (provider.status().extensionConnected) {
      await resolveAutomatically(asked.questionId)
      return "connected"
    }
    let unsubscribe = (): void => undefined
    const connected = new Promise<"connected">((resolve) => {
      unsubscribe = provider.onExtensionConnectionChange((isConnected) => {
        if (isConnected) resolve("connected")
      })
    })
    const result = await Promise.race([asked.answer, connected])
    unsubscribe()
    if (result === "connected") await resolveAutomatically(asked.questionId)
    return result
  }

  const chromeSetup = async (
    sessionId: string,
    persistPreference = true
  ): Promise<BrowserChoice> => {
    const finish = (backend: BrowserBackend): Promise<BrowserBackend> =>
      persistPreference ? remember(backend) : Promise.resolve(backend)
    let installerOpened = false
    while (true) {
      if (provider.status().extensionConnected) return finish("extension")
      const development = provider.status().extensionSetupMode === "development"
      const setup = await ask(sessionId, {
        id: "browser_preference",
        header: installerOpened ? "Finish in Chrome" : "Connect Chrome",
        question: "Drop the Codevisor extension folder into the Extensions page in Chrome.",
        options: development
          ? [
              {
                label: "Open Extensions",
                description: "Open the Extensions page in Chrome."
              },
              {
                label: "Show Folder",
                description: "Show the Codevisor extension folder in Finder."
              }
            ]
          : [
              {
                label: "Open Web Store",
                description: "Install Codevisor from the Chrome Web Store."
              }
            ],
        multiSelect: false,
        allowsOther: false,
        backOptionLabel: "Back",
        presentation: installerOpened ? "browserExtensionWaiting" : "browserExtensionSetup"
      })
      const result = await waitForConnectionOrAnswer(setup)
      if (result === "connected") return finish("extension")
      if (result.outcome !== "answered") throw rejection(result)
      switch (selectedAnswer(result).label) {
        case "Back":
          return "back"
        case "Show Folder":
          provider.openDevelopmentExtensionFolder()
          installerOpened = true
          break
        case "Open Extensions":
          provider.openDevelopmentExtensionPage()
          installerOpened = true
          break
        case "Open Web Store":
          provider.openExtensionWebStore()
          installerOpened = true
          break
        default:
          throw rejection(result)
      }
    }
  }

  const choose = async (sessionId: string): Promise<BrowserBackend> => {
    while (true) {
      const chromeAvailable = provider.status().chromeAvailable
      const choice = await ask(sessionId, {
        id: "browser_preference",
        header: "Browser Use",
        question: "Which browser should I use?",
        options: [
          ...(chromeAvailable
            ? [
                {
                  label: "Use Google Chrome",
                  description: "Use your existing tabs and signed-in Chrome session."
                }
              ]
            : []),
          {
            label: "Use Codevisor Browser",
            description: "Use a separate browser managed by Codevisor."
          }
        ],
        multiSelect: false,
        allowsOther: true
      })
      const answer = await choice.answer
      if (answer.outcome !== "answered") throw rejection(answer)
      switch (selectedAnswer(answer).label) {
        case "Use Codevisor Browser":
          return remember("managed")
        case "Use Google Chrome": {
          const configured = await chromeSetup(sessionId)
          if (configured !== "back") return configured
          break
        }
        default:
          throw rejection(answer)
      }
    }
  }

  const resolveBackend = async (
    sessionId: string,
    requested?: BrowserBackend
  ): Promise<BrowserBackend> => {
    const session = provider.sessionBackend(sessionId)
    if (
      session !== undefined &&
      requested === undefined &&
      (session !== "extension" || provider.status().extensionConnected)
    )
      return session
    if (requested === "managed") {
      provider.setSessionBackend(sessionId, "managed")
      return "managed"
    }
    const existing = active.get(sessionId)
    if (existing !== undefined) return existing
    const resolving = (async () => {
      let backend: BrowserBackend
      if (requested === "extension") {
        const configured = await chromeSetup(sessionId, false)
        backend = configured === "back" ? await choose(sessionId) : configured
      } else {
        const preference = await run(db.getBrowserPreference)
        if (preference === "managed") backend = "managed"
        else if (preference === "chrome" && provider.status().extensionConnected) {
          backend = "extension"
        } else if (preference === "chrome" && provider.status().chromeAvailable) {
          const configured = await chromeSetup(sessionId)
          backend = configured === "back" ? await choose(sessionId) : configured
        } else backend = await choose(sessionId)
      }
      provider.setSessionBackend(sessionId, backend)
      return backend
    })().finally(() => active.delete(sessionId))
    active.set(sessionId, resolving)
    return resolving
  }

  return {
    setSink: (sessionId, sink) => sinks.set(sessionId, sink),
    resolveBackend,
    answerQuestion: async (sessionId, questionId, answer) => {
      const current = pending.get(questionId)
      if (current === undefined || current.sessionId !== sessionId) return false
      pending.delete(questionId)
      const resolved: QuestionResolvedPayload = {
        outcome: answer.outcome === "answered" ? "answered" : "cancelled",
        questionId,
        questions: current.questions,
        sessionUpdate: "question_resolved",
        ...(answer.outcome === "answered" && answer.answers !== undefined
          ? { answers: answer.answers }
          : {})
      }
      await emit(sessionId, resolved)
      current.resolve(answer)
      return true
    },
    closeSession: async (sessionId) => {
      sinks.delete(sessionId)
      for (const [questionId, current] of pending) {
        if (current.sessionId !== sessionId) continue
        pending.delete(questionId)
        current.resolve({ outcome: "cancelled" })
      }
      active.delete(sessionId)
    },
    close: async () => {
      for (const current of pending.values()) current.resolve({ outcome: "cancelled" })
      pending.clear()
      active.clear()
      sinks.clear()
    }
  }
}
