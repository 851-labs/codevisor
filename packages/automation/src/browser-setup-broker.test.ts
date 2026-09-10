import type { RuntimeEvent } from "@codevisor/agent-runtime"
import type { CodevisorDatabaseService } from "@codevisor/db"
import { Effect } from "effect"
import { describe, expect, it, vi } from "vitest"
import { makeBrowserSetupBroker } from "./browser-setup-broker.js"
import type { BrowserBackend, BrowserUseProvider } from "./browser-use-provider.js"

const fixture = (
  options: {
    chrome?: boolean
    connected?: boolean
    preference?: string
    setupMode?: "development" | "webStore"
  } = {}
) => {
  let preference = options.preference
  let connected = options.connected ?? false
  const listeners = new Set<(connected: boolean) => void>()
  const backends = new Map<string, BrowserBackend>()
  const showFolder = vi.fn()
  const openExtensions = vi.fn()
  const openWebStore = vi.fn()
  const db = {
    getBrowserPreference: Effect.sync(() => preference),
    setBrowserPreference: (value: "chrome" | "managed" | "builtin" | undefined) =>
      Effect.sync(() => {
        preference = value
      })
  } as unknown as CodevisorDatabaseService
  const provider = {
    status: () => ({
      backend: "systemChrome",
      chromeAvailable: options.chrome ?? true,
      developmentExtensionPath: "/tmp/Codevisor",
      extensionConnected: connected,
      extensionSetupMode: options.setupMode ?? "development"
    }),
    beginTurn: async (sessionId: string, backend: BrowserBackend) => {
      backends.set(sessionId, backend)
    },
    sessionBackend: (sessionId: string) => backends.get(sessionId),
    setSessionBackend: (sessionId: string, backend: BrowserBackend) =>
      backends.set(sessionId, backend),
    onExtensionConnectionChange: (listener: (value: boolean) => void) => {
      listeners.add(listener)
      return () => listeners.delete(listener)
    },
    openDevelopmentExtensionFolder: showFolder,
    openDevelopmentExtensionPage: openExtensions,
    openExtensionWebStore: openWebStore
  } as unknown as BrowserUseProvider
  const events: RuntimeEvent[] = []
  let questionCount = 0
  let consumedQuestions = 0
  const waiters = new Map<number, () => void>()
  const broker = makeBrowserSetupBroker(db, provider)
  broker.setSink("session", async (event) => {
    events.push(event)
    if ((event.payload as { sessionUpdate?: string }).sessionUpdate === "question") {
      questionCount += 1
      waiters.get(questionCount)?.()
      waiters.delete(questionCount)
    }
  })
  return {
    nextQuestion: () => {
      consumedQuestions += 1
      return questionCount >= consumedQuestions
        ? Promise.resolve()
        : new Promise<void>((resolve) => waiters.set(consumedQuestions, resolve))
    },
    broker,
    events,
    showFolder,
    openExtensions,
    openWebStore,
    preference: () => preference,
    setPreference: (value: string) => {
      preference = value
    },
    connect: () => {
      connected = true
      for (const listener of listeners) listener(true)
    },
    disconnect: () => {
      connected = false
      for (const listener of listeners) listener(false)
    }
  }
}

const latestQuestionId = (events: RuntimeEvent[]): string => {
  const payload = events.at(-1)?.payload as { questionId?: string }
  if (payload.questionId === undefined) throw new Error("Missing browser question")
  return payload.questionId
}

const answer = (
  broker: ReturnType<typeof makeBrowserSetupBroker>,
  events: RuntimeEvent[],
  label?: string,
  note?: string
) =>
  broker.answerQuestion("session", latestQuestionId(events), {
    outcome: "answered",
    answers: {
      browser_preference: {
        answers: label === undefined ? [] : [label],
        ...(note === undefined ? {} : { note })
      }
    }
  })

describe("browser setup broker", () => {
  it("defaults to built-in without a picker and preserves explicit preferences", async () => {
    const current = fixture({ chrome: false })
    await expect(current.broker.resolveBackend("session")).resolves.toBe("builtin")
    expect(current.events).toHaveLength(0)
    expect(current.preference()).toBeUndefined()
    for (const backend of ["managed", "builtin"] as const) {
      const explicit = fixture({ preference: "chrome" })
      await expect(explicit.broker.resolveBackend("session", backend)).resolves.toBe(backend)
      expect(explicit.events).toHaveLength(0)
      expect(explicit.preference()).toBe("chrome")
      const saved = fixture({ preference: backend })
      await expect(saved.broker.resolveBackend("session")).resolves.toBe(backend)
    }
  })

  it("resumes when Chrome is connected from another client", async () => {
    const current = fixture({ preference: "chrome" })
    const resolving = current.broker.resolveBackend("session")
    await current.nextQuestion()

    const setup = current.events.at(-1)!.payload as {
      questions: Array<{ backOptionLabel?: string; presentation?: string }>
    }
    expect(setup.questions[0]).toMatchObject({
      backOptionLabel: "Back",
      presentation: "browserExtensionSetup"
    })

    // The client showing this question may be remote. Opening the same chat
    // on the host machine and connecting Chrome resolves the held call for
    // every client without invoking a setup action from this one.
    current.connect()
    await expect(resolving).resolves.toBe("extension")
    expect(current.preference()).toBe("chrome")
    expect(current.openExtensions).not.toHaveBeenCalled()
    expect(
      current.events.some(
        (event) =>
          (event.payload as { sessionUpdate?: string; outcome?: string }).sessionUpdate ===
            "question_resolved" &&
          (event.payload as { outcome?: string }).outcome === "autoResolved"
      )
    ).toBe(true)
  })

  it("treats an explicit Chrome request as a session override", async () => {
    const current = fixture({ connected: true, preference: "managed" })
    await expect(current.broker.resolveBackend("session", "extension")).resolves.toBe("extension")
    expect(current.events).toHaveLength(0)
    expect(current.preference()).toBe("managed")
  })

  it("does not silently switch a missing explicit extension preference", async () => {
    const current = fixture({ chrome: false, preference: "chrome" })
    await expect(current.broker.resolveBackend("session")).rejects.toThrow(
      "Codevisor Extension requires Chrome"
    )
    expect(current.events).toHaveLength(0)
    expect(current.preference()).toBe("chrome")
  })

  it("uses Back as navigation without rejecting the held call", async () => {
    const current = fixture({ preference: "chrome" })
    const resolving = current.broker.resolveBackend("session")
    await current.nextQuestion()
    const setup = current.events.at(-1)!.payload as {
      message?: string
      questions: Array<{
        allowsOther: boolean
        backOptionLabel?: string
        presentation?: string
        options: Array<{ label: string }>
      }>
    }
    expect(setup.message).toBeUndefined()
    expect(setup.questions[0]).toMatchObject({
      allowsOther: false,
      backOptionLabel: "Back",
      presentation: "browserExtensionSetup",
      options: [{ label: "Open Extensions" }]
    })
    await answer(current.broker, current.events, "Back")
    await current.nextQuestion()
    const question = (current.events.at(-1)!.payload as { questions: Array<{ question: string }> })
      .questions[0]?.question
    expect(question).toBe("Which browser should I use?")
    await answer(current.broker, current.events, "Use Chromium")
    await expect(resolving).resolves.toBe("managed")
  })

  it("opens Chrome Extensions and auto-resumes when the extension connects", async () => {
    const current = fixture({ preference: "chrome" })
    const resolving = current.broker.resolveBackend("session")
    await current.nextQuestion()
    await answer(current.broker, current.events, "Open Extensions")
    await current.nextQuestion()
    expect(current.openExtensions).toHaveBeenCalledOnce()
    expect(current.showFolder).not.toHaveBeenCalled()
    const waiting = current.events.at(-1)!.payload as {
      message?: string
      questions: Array<{
        allowsOther: boolean
        backOptionLabel?: string
        presentation?: string
        options: Array<{ label: string }>
      }>
    }
    expect(waiting.message).toBeUndefined()
    expect(waiting.questions[0]).toMatchObject({
      allowsOther: false,
      backOptionLabel: "Back",
      presentation: "browserExtensionWaiting",
      options: [{ label: "Open Extensions" }]
    })
    current.connect()
    await expect(resolving).resolves.toBe("extension")
    expect(current.preference()).toBe("chrome")
    expect(
      current.events.some(
        (event) =>
          (event.payload as { sessionUpdate?: string; outcome?: string }).sessionUpdate ===
            "question_resolved" &&
          (event.payload as { outcome?: string }).outcome === "autoResolved"
      )
    ).toBe(true)
  })

  it("uses the packaged extension guide in production", async () => {
    const current = fixture({ setupMode: "webStore" })
    const resolving = current.broker.resolveBackend("session", "extension")
    await current.nextQuestion()
    const setup = current.events.at(-1)!.payload as {
      questions: Array<{ options: Array<{ label: string }> }>
    }
    expect(setup.questions[0]?.options).toEqual([
      {
        label: "Open Extensions",
        description: "Open the Extensions page in Chrome."
      }
    ])

    await answer(current.broker, current.events, "Open Extensions")
    await current.nextQuestion()
    expect(current.openExtensions).toHaveBeenCalledOnce()
    expect(current.openWebStore).not.toHaveBeenCalled()
    expect(current.showFolder).not.toHaveBeenCalled()
    current.connect()
    await expect(resolving).resolves.toBe("extension")
  })

  it("reopens extension setup when Chrome disconnects after being selected", async () => {
    const current = fixture({ connected: true, preference: "chrome" })
    await expect(current.broker.resolveBackend("session")).resolves.toBe("extension")

    current.disconnect()
    const reconnecting = current.broker.resolveBackend("session")
    await current.nextQuestion()
    const setup = current.events.at(-1)!.payload as {
      questions: Array<{ presentation?: string; question: string }>
    }
    expect(setup.questions[0]).toMatchObject({
      presentation: "browserExtensionSetup",
      question: "Drag the Codevisor extension into the Extensions page in Chrome."
    })

    await answer(current.broker, current.events, "Open Extensions")
    await current.nextQuestion()
    expect(current.openExtensions).toHaveBeenCalledOnce()
    current.connect()
    await expect(reconnecting).resolves.toBe("extension")
  })

  it("turns invalid answers and Escape into deterministic tool rejection", async () => {
    const other = fixture()
    const otherCall = other.broker.resolveBackend("session", "extension")
    await other.nextQuestion()
    await answer(other.broker, other.events, undefined, "Do not use a browser")
    await expect(otherCall).rejects.toThrow("Do not use a browser")

    const dismissed = fixture()
    const dismissedCall = dismissed.broker.resolveBackend("session", "extension")
    await dismissed.nextQuestion()
    await dismissed.broker.answerQuestion("session", latestQuestionId(dismissed.events), {
      outcome: "cancelled"
    })
    await expect(dismissedCall).rejects.toThrow("The user rejected Browser Use")
  })
})

it("snapshots the saved preference at response boundaries, including before the first browser call", async () => {
  const f = fixture({ preference: "managed", connected: true })
  try {
    await f.broker.beginTurn("session")
    f.setPreference("builtin")
    expect(await f.broker.resolveBackend("session")).toBe("managed")
    await f.broker.beginTurn("session")
    expect(await f.broker.resolveBackend("session")).toBe("builtin")
    expect(await f.broker.resolveBackend("session", "managed")).toBe("managed")
    expect(await f.broker.resolveBackend("session")).toBe("managed")
    await f.broker.beginTurn("session")
    expect(await f.broker.resolveBackend("session")).toBe("builtin")
    f.setPreference("chrome")
    expect(await f.broker.resolveBackend("session")).toBe("builtin")
    await f.broker.beginTurn("session")
    expect(await f.broker.resolveBackend("session")).toBe("extension")
  } finally {
    await f.broker.close()
  }
})
