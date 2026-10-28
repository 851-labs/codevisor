import type { RuntimeEvent } from "@codevisor/agent-runtime"
import { afterEach, describe, expect, it, vi } from "vitest"

import { EXTENSION_INSTALL_PROMPT_MS, makeBrowserSetupBroker } from "./browser-setup-broker.js"
import type { BrowserBackend, BrowserUseProvider } from "./browser-use-provider.js"
import { recordOrEmpty, recordsIn } from "./unknown-values.js"

const fixture = (
  options: {
    chrome?: boolean
    connected?: boolean
    setupMode?: "development" | "webStore"
  } = {}
) => {
  let connected = options.connected ?? false
  const listeners = new Set<(connected: boolean) => void>()
  const backends = new Map<string, BrowserBackend>()
  const openExtensions = vi.fn(async () => {})
  const openWebStore = vi.fn(async () => {})
  const provider: BrowserUseProvider = {
    id: "browser",
    tools: [],
    invoke: async () => ({ content: [] }),
    closeSession: async () => {},
    close: async () => {},
    ensureSetup: async () => {},
    acceptBrowserHost: () => {},
    acceptExtensionConnection: () => {},
    acceptNativeHostConnection: () => {},
    openDevelopmentExtensionInstaller: async () => {},
    extensionArchivePath: () => "",
    extensionIconPath: () => "",
    configureExtensionRelay: () => {},
    status: () => ({
      backend: "systemChrome",
      chromeAvailable: options.chrome ?? true,
      developmentExtensionPath: "/tmp/Codevisor",
      extensionConnected: connected,
      extensionSetupMode: options.setupMode ?? "development"
    }),
    beginTurn: async () => {},
    sessionBackend: (sessionId: string) => backends.get(sessionId),
    setSessionBackend: (sessionId: string, backend: BrowserBackend) =>
      backends.set(sessionId, backend),
    onExtensionConnectionChange: (listener: (value: boolean) => void) => {
      listeners.add(listener)
      return () => listeners.delete(listener)
    },
    openDevelopmentExtensionFolder: async () => {},
    openDevelopmentExtensionPage: openExtensions,
    openExtensionWebStore: openWebStore
  }
  const events: RuntimeEvent[] = []
  let questionCount = 0
  let consumedQuestions = 0
  const waiters = new Map<number, () => void>()
  const broker = makeBrowserSetupBroker(provider)
  broker.setSink("session", async (event) => {
    events.push(event)
    if (recordOrEmpty(event.payload).sessionUpdate === "question") {
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
    backends,
    events,
    openExtensions,
    openWebStore,
    connect: () => {
      connected = true
      for (const listener of listeners) listener(true)
    }
  }
}

const latestPayload = (events: RuntimeEvent[]) => recordOrEmpty(events.at(-1)?.payload)

const latestQuestions = (events: RuntimeEvent[]) => recordsIn(latestPayload(events).questions)

const resolutions = (events: RuntimeEvent[]) =>
  events
    .map((event) => recordOrEmpty(event.payload))
    .filter((payload) => payload.sessionUpdate === "question_resolved")
    .map((payload) => payload.outcome)

const latestQuestionId = (events: RuntimeEvent[]): string => {
  const { questionId } = latestPayload(events)
  if (typeof questionId !== "string") throw new Error("Missing browser question")
  return questionId
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

afterEach(() => {
  vi.useRealTimers()
})

describe("Chrome extension install prompt", () => {
  it("selects an already connected Chrome without showing the card", async () => {
    const current = fixture({ connected: true })
    await expect(current.broker.requestExtensionInstall("session", {})).resolves.toEqual({
      outcome: "installed"
    })
    expect(current.events).toHaveLength(0)
    expect(current.backends.get("session")).toBe("extension")
  })

  it("shows the Chrome setup card and returns installed once Chrome connects", async () => {
    const current = fixture()
    const requested = current.broker.requestExtensionInstall("session", {})
    await current.nextQuestion()
    expect(latestQuestions(current.events)[0]).toMatchObject({
      question: "Drag the Codevisor extension into the Extensions page in Chrome.",
      presentation: "browserExtensionSetup",
      options: [{ label: "Open Extensions" }]
    })
    expect(latestQuestions(current.events)[0]?.backOptionLabel).toBeUndefined()

    current.connect()
    await expect(requested).resolves.toEqual({ outcome: "installed" })
    expect(resolutions(current.events)).toEqual(["autoResolved"])
    expect(current.backends.get("session")).toBe("extension")
  })

  it("opens Chrome's Extensions page and keeps waiting", async () => {
    const current = fixture()
    const requested = current.broker.requestExtensionInstall("session", {})
    await current.nextQuestion()
    await answer(current.broker, current.events, "Open Extensions")
    await current.nextQuestion()
    expect(current.openExtensions).toHaveBeenCalledOnce()
    expect(latestQuestions(current.events)[0]).toMatchObject({
      presentation: "browserExtensionWaiting"
    })
    current.connect()
    await expect(requested).resolves.toEqual({ outcome: "installed" })
  })

  it("opens the Chrome Web Store listing in release builds", async () => {
    const current = fixture({ setupMode: "webStore" })
    const requested = current.broker.requestExtensionInstall("session", {})
    await current.nextQuestion()
    expect(latestQuestions(current.events)[0]).toMatchObject({
      question: "Add the Codevisor extension to Chrome from the Chrome Web Store.",
      options: [
        {
          label: "Add to Chrome",
          description: "Open the Codevisor listing in the Chrome Web Store."
        }
      ]
    })
    await answer(current.broker, current.events, "Add to Chrome")
    await current.nextQuestion()
    expect(current.openWebStore).toHaveBeenCalledOnce()
    expect(current.openExtensions).not.toHaveBeenCalled()
    current.connect()
    await expect(requested).resolves.toEqual({ outcome: "installed" })
  })

  it("returns dismissed when the user closes the card or answers otherwise", async () => {
    const closed = fixture()
    const closedRequest = closed.broker.requestExtensionInstall("session", {})
    await closed.nextQuestion()
    await closed.broker.answerQuestion("session", latestQuestionId(closed.events), {
      outcome: "cancelled"
    })
    await expect(closedRequest).resolves.toEqual({ outcome: "dismissed" })
    expect(closed.backends.has("session")).toBe(false)

    const noted = fixture()
    const notedRequest = noted.broker.requestExtensionInstall("session", {})
    await noted.nextQuestion()
    await answer(noted.broker, noted.events, undefined, "Use the built-in browser")
    await expect(notedRequest).resolves.toEqual({
      outcome: "dismissed",
      note: "Use the built-in browser"
    })
  })

  it("times out after ten minutes and clears the card", async () => {
    vi.useFakeTimers()
    const current = fixture()
    const settled = vi.fn()
    const requested = current.broker.requestExtensionInstall("session", {}).then(settled)
    await current.nextQuestion()
    await vi.advanceTimersByTimeAsync(EXTENSION_INSTALL_PROMPT_MS - 1)
    expect(settled).not.toHaveBeenCalled()
    await vi.advanceTimersByTimeAsync(1)
    await requested
    expect(settled).toHaveBeenCalledWith({ outcome: "timeout" })
    expect(resolutions(current.events)).toEqual(["cancelled"])
  })

  it("times out at the execute deadline when that comes first", async () => {
    vi.useFakeTimers({ toFake: ["setTimeout", "clearTimeout", "performance"] })
    const current = fixture()
    const settled = vi.fn()
    const requested = current.broker
      .requestExtensionInstall("session", { deadline: performance.now() + 6_000 })
      .then(settled)
    await current.nextQuestion()
    await vi.advanceTimersByTimeAsync(4_999)
    expect(settled).not.toHaveBeenCalled()
    await vi.advanceTimersByTimeAsync(1)
    await requested
    expect(settled).toHaveBeenCalledWith({ outcome: "timeout" })
  })

  it("rejects and clears the card when the turn is interrupted or the chat closes", async () => {
    const interrupted = fixture()
    const controller = new AbortController()
    const request = interrupted.broker.requestExtensionInstall("session", {
      signal: controller.signal
    })
    await interrupted.nextQuestion()
    controller.abort()
    await expect(request).rejects.toThrow("interrupted")
    expect(resolutions(interrupted.events)).toEqual(["cancelled"])

    const closed = fixture()
    const closing = closed.broker.requestExtensionInstall("session", {})
    await closed.nextQuestion()
    await closed.broker.closeSession("session")
    await expect(closing).rejects.toThrow("chat closed")
    expect(resolutions(closed.events)).toEqual(["cancelled"])
  })

  it("refuses when Chrome isn't installed", async () => {
    const current = fixture({ chrome: false })
    await expect(current.broker.requestExtensionInstall("session", {})).rejects.toThrow(
      "Google Chrome isn't installed"
    )
    expect(current.events).toHaveLength(0)
  })
})

describe("Computer Use permission prompt", () => {
  it("shows one card for concurrent calls and continues once the user grants access", async () => {
    const current = fixture()
    const first = current.broker.requestComputerUsePermissions("session", {})
    const second = current.broker.requestComputerUsePermissions("session", {})
    await current.nextQuestion()
    expect(latestQuestions(current.events)[0]).toMatchObject({
      presentation: "computerUsePermissions",
      options: [{ label: "Continue" }]
    })
    await current.broker.answerQuestion("session", latestQuestionId(current.events), {
      outcome: "answered",
      answers: { computer_use_permissions: { answers: ["Continue"] } }
    })
    await expect(first).resolves.toBe(true)
    await expect(second).resolves.toBe(true)
    expect(
      current.events.filter((event) => recordOrEmpty(event.payload).sessionUpdate === "question")
    ).toHaveLength(1)
  })

  it("returns false when the user dismisses the card or it times out", async () => {
    const dismissed = fixture()
    const request = dismissed.broker.requestComputerUsePermissions("session", {})
    await dismissed.nextQuestion()
    await dismissed.broker.answerQuestion("session", latestQuestionId(dismissed.events), {
      outcome: "cancelled"
    })
    await expect(request).resolves.toBe(false)

    vi.useFakeTimers()
    const idle = fixture()
    const timedOut = idle.broker.requestComputerUsePermissions("session", {})
    await idle.nextQuestion()
    await vi.advanceTimersByTimeAsync(EXTENSION_INSTALL_PROMPT_MS)
    await expect(timedOut).resolves.toBe(false)
    expect(resolutions(idle.events)).toEqual(["cancelled"])
  })

  it("clears the card when the turn ends before the user answers", async () => {
    const current = fixture()
    const request = current.broker.requestComputerUsePermissions("session", {})
    await current.nextQuestion()
    await current.broker.finishTurn("session")
    await expect(request).resolves.toBe(false)
    expect(resolutions(current.events)).toEqual(["cancelled"])
  })
})
