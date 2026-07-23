import type { RuntimeEvent } from "@codevisor/agent-runtime"
import type { CodevisorDatabaseService } from "@codevisor/db"
import { Effect } from "effect"
import { describe, expect, it, vi } from "vitest"
import { makeBrowserSetupBroker } from "./browser-setup-broker.js"
import type { BrowserBackend, BrowserUseProvider } from "./browser-use-provider.js"

const tick = () => new Promise<void>((resolve) => setTimeout(resolve, 0))

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
    setBrowserPreference: (value: "chrome" | "managed" | undefined) =>
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
  const broker = makeBrowserSetupBroker(db, provider)
  broker.setSink("session", async (event) => {
    events.push(event)
  })
  return {
    broker,
    events,
    showFolder,
    openExtensions,
    openWebStore,
    preference: () => preference,
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
  it("asks once, remembers the choice, and lets explicit managed selection bypass UI", async () => {
    const selected = fixture({ chrome: false })
    const resolving = selected.broker.resolveBackend("session")
    await tick()
    expect(
      (selected.events.at(-1)!.payload as { questions: Array<{ question: string }> }).questions[0]
        ?.question
    ).toBe("Which browser should I use?")
    await answer(selected.broker, selected.events, "Use Codevisor Browser")
    await expect(resolving).resolves.toBe("managed")
    expect(selected.preference()).toBe("managed")

    const explicit = fixture()
    await expect(explicit.broker.resolveBackend("session", "managed")).resolves.toBe("managed")
    expect(explicit.events).toHaveLength(0)
    expect(explicit.preference()).toBeUndefined()
  })

  it("treats an explicit Chrome request as a session override", async () => {
    const current = fixture({ connected: true, preference: "managed" })
    await expect(current.broker.resolveBackend("session", "extension")).resolves.toBe("extension")
    expect(current.events).toHaveLength(0)
    expect(current.preference()).toBe("managed")
  })

  it("asks again when a saved Chrome preference is no longer available", async () => {
    const current = fixture({ chrome: false, preference: "chrome" })
    const resolving = current.broker.resolveBackend("session")
    await tick()
    const options = (
      current.events.at(-1)!.payload as {
        questions: Array<{ options: Array<{ label: string }> }>
      }
    ).questions[0]?.options
    expect(options?.map((option) => option.label)).toEqual(["Use Codevisor Browser"])
    await answer(current.broker, current.events, "Use Codevisor Browser")
    await expect(resolving).resolves.toBe("managed")
  })

  it("uses Back as navigation without rejecting the held call", async () => {
    const current = fixture()
    const resolving = current.broker.resolveBackend("session")
    await tick()
    await answer(current.broker, current.events, "Use Google Chrome")
    await tick()
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
      options: [{ label: "Open Extensions" }, { label: "Show Folder" }]
    })
    await answer(current.broker, current.events, "Back")
    await tick()
    const question = (current.events.at(-1)!.payload as { questions: Array<{ question: string }> })
      .questions[0]?.question
    expect(question).toBe("Which browser should I use?")
    await answer(current.broker, current.events, "Use Codevisor Browser")
    await expect(resolving).resolves.toBe("managed")
  })

  it("opens each development setup destination and auto-resumes when the extension connects", async () => {
    const current = fixture()
    const resolving = current.broker.resolveBackend("session")
    await tick()
    await answer(current.broker, current.events, "Use Google Chrome")
    await tick()
    await answer(current.broker, current.events, "Open Extensions")
    await tick()
    expect(current.openExtensions).toHaveBeenCalledOnce()
    expect(current.showFolder).not.toHaveBeenCalled()
    await answer(current.broker, current.events, "Show Folder")
    await tick()
    expect(current.showFolder).toHaveBeenCalledOnce()
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
      options: [{ label: "Open Extensions" }, { label: "Show Folder" }]
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

  it("uses the Chrome Web Store flow in production", async () => {
    const current = fixture({ setupMode: "webStore" })
    const resolving = current.broker.resolveBackend("session", "extension")
    await tick()
    const setup = current.events.at(-1)!.payload as {
      questions: Array<{ options: Array<{ label: string }> }>
    }
    expect(setup.questions[0]?.options).toEqual([
      {
        label: "Open Web Store",
        description: "Install Codevisor from the Chrome Web Store."
      }
    ])

    await answer(current.broker, current.events, "Open Web Store")
    await tick()
    expect(current.openWebStore).toHaveBeenCalledOnce()
    expect(current.showFolder).not.toHaveBeenCalled()
    expect(current.openExtensions).not.toHaveBeenCalled()
    current.connect()
    await expect(resolving).resolves.toBe("extension")
  })

  it("reopens extension setup when Chrome disconnects after being selected", async () => {
    const current = fixture({ connected: true, preference: "chrome" })
    await expect(current.broker.resolveBackend("session")).resolves.toBe("extension")

    current.disconnect()
    const reconnecting = current.broker.resolveBackend("session")
    await tick()
    const setup = current.events.at(-1)!.payload as {
      questions: Array<{ presentation?: string; question: string }>
    }
    expect(setup.questions[0]).toMatchObject({
      presentation: "browserExtensionSetup",
      question: "Drop the Codevisor extension folder into the Extensions page in Chrome."
    })

    await answer(current.broker, current.events, "Open Extensions")
    await tick()
    expect(current.openExtensions).toHaveBeenCalledOnce()
    current.connect()
    await expect(reconnecting).resolves.toBe("extension")
  })

  it("turns Other and Escape into deterministic tool rejection", async () => {
    const other = fixture()
    const otherCall = other.broker.resolveBackend("session")
    await tick()
    await answer(other.broker, other.events, undefined, "Do not use a browser")
    await expect(otherCall).rejects.toThrow("Do not use a browser")

    const dismissed = fixture()
    const dismissedCall = dismissed.broker.resolveBackend("session")
    await tick()
    await dismissed.broker.answerQuestion("session", latestQuestionId(dismissed.events), {
      outcome: "cancelled"
    })
    await expect(dismissedCall).rejects.toThrow("The user rejected Browser Use")
  })
})
