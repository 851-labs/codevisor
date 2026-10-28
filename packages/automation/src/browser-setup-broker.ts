import { randomUUID } from "node:crypto"

import type { QuestionAnswer, RuntimeEventSink } from "@codevisor/agent-runtime"
import type { QuestionResolvedPayload, QuestionSpec } from "@codevisor/api"

import type {
  BrowserClientPlatform,
  BrowserExtensionSetupMode,
  BrowserUseProvider
} from "./browser-use-provider-types.js"

export const EXTENSION_INSTALL_PROMPT_MS = 10 * 60_000
const DEADLINE_MARGIN_MS = 1_000

export type ExtensionInstallOutcome =
  | { readonly outcome: "installed" }
  | { readonly outcome: "dismissed"; readonly note?: string }
  | { readonly outcome: "timeout" }

export interface ExtensionInstallRequest {
  readonly signal?: AbortSignal | undefined
  readonly deadline?: number | undefined
}

type Settled = QuestionAnswer | { readonly outcome: "closed" }

interface PendingQuestion {
  readonly sessionId: string
  readonly questions: ReadonlyArray<QuestionSpec>
  readonly resolve: (answer: Settled) => void
}

export interface BrowserSetupBroker {
  readonly beginTurn: (
    sessionId: string,
    options?: { readonly clientPlatform?: BrowserClientPlatform | undefined }
  ) => Promise<void>
  readonly setSink: (sessionId: string, sink: RuntimeEventSink) => void
  readonly requestExtensionInstall: (
    sessionId: string,
    request: ExtensionInstallRequest
  ) => Promise<ExtensionInstallOutcome>
  readonly requestComputerUsePermissions: (
    sessionId: string,
    request: ExtensionInstallRequest
  ) => Promise<boolean>
  readonly answerQuestion: (
    sessionId: string,
    questionId: string,
    answer: QuestionAnswer
  ) => Promise<boolean>
  readonly finishTurn: (sessionId: string) => Promise<void>
  readonly closeSession: (sessionId: string) => Promise<void>
  readonly close: () => Promise<void>
}

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

type PromptStop = "timeout" | "interrupted"

const permissionPromptInterrupted =
  "The Computer Use prompt was interrupted before the user answered."
const permissionPromptClosed = "The chat closed before the user answered the Computer Use prompt."

const computerUsePermissionsQuestion: QuestionSpec = {
  id: "computer_use_permissions",
  header: "Allow Computer Use",
  question: "Turn on Accessibility for Codevisor on the Mac running this chat.",
  options: [{ label: "Continue" }],
  multiSelect: false,
  allowsOther: false,
  presentation: "computerUsePermissions"
}

interface ExtensionSetupCopy {
  readonly installQuestion: string
  readonly installOption: { readonly label: string; readonly description: string }
}

const extensionSetupCopy: Record<BrowserExtensionSetupMode, ExtensionSetupCopy> = {
  development: {
    installQuestion: "Drag the Codevisor extension into the Extensions page in Chrome.",
    installOption: { label: "Open Extensions", description: "Open the Extensions page in Chrome." }
  },
  webStore: {
    installQuestion: "Add the Codevisor extension to Chrome from the Chrome Web Store.",
    installOption: {
      label: "Add to Chrome",
      description: "Open the Codevisor listing in the Chrome Web Store."
    }
  }
}

const promptLimit = (deadline: number | undefined): number =>
  Math.min(
    EXTENSION_INSTALL_PROMPT_MS,
    (deadline ?? Infinity) - DEADLINE_MARGIN_MS - performance.now()
  )

const answerWithin = async <Answer>(
  answer: Promise<Answer>,
  limit: number,
  signal: AbortSignal | undefined
): Promise<Answer | PromptStop> => {
  if (signal?.aborted === true) return "interrupted"
  const { promise: stopped, resolve: stop } = Promise.withResolvers<PromptStop>()
  const timer = setTimeout(() => stop("timeout"), limit)
  const interrupt = () => stop("interrupted")
  signal?.addEventListener("abort", interrupt, { once: true })
  try {
    return await Promise.race([answer, stopped])
  } finally {
    clearTimeout(timer)
    signal?.removeEventListener("abort", interrupt)
  }
}

export const makeBrowserSetupBroker = (provider: BrowserUseProvider): BrowserSetupBroker => {
  const sinks = new Map<string, RuntimeEventSink>()
  const pending = new Map<string, PendingQuestion>()

  const emit = async (sessionId: string, payload: unknown): Promise<void> => {
    const sink = sinks.get(sessionId)
    if (sink === undefined) throw new Error("Browser setup requires an active Codevisor session")
    await sink({ kind: "session.output", subjectId: sessionId, payload })
  }

  const ask = async (sessionId: string, question: QuestionSpec) => {
    const questionId = `browser-setup:${randomUUID()}`
    const questions = [question]
    const answer = new Promise<Settled>((resolve) => {
      pending.set(questionId, { sessionId, questions, resolve })
    })
    try {
      await emit(sessionId, { questionId, questions, sessionUpdate: "question" })
    } catch (cause) {
      pending.delete(questionId)
      throw cause
    }
    return { questionId, answer }
  }

  const resolveQuestion = async (questionId: string, outcome: "autoResolved" | "cancelled") => {
    const current = pending.get(questionId)
    if (current === undefined) return
    pending.delete(questionId)
    const resolved: QuestionResolvedPayload = {
      outcome,
      questionId,
      questions: current.questions,
      sessionUpdate: "question_resolved"
    }
    await emit(current.sessionId, resolved).catch(() => undefined)
  }

  const settlePending = async (
    matches: (current: PendingQuestion) => boolean,
    settled: Settled
  ) => {
    for (const [questionId, current] of pending) {
      if (!matches(current)) continue
      await resolveQuestion(questionId, "cancelled")
      current.resolve(settled)
    }
  }

  const setupMode = () => provider.status().extensionSetupMode

  const openExtensionSetup = (): Promise<void> => {
    if (setupMode() === "webStore") return provider.openExtensionWebStore()
    return provider.openDevelopmentExtensionPage()
  }

  const installed = (sessionId: string): ExtensionInstallOutcome => {
    provider.setSessionBackend(sessionId, "extension")
    return { outcome: "installed" }
  }

  const requestExtensionInstall = async (
    sessionId: string,
    { signal, deadline }: ExtensionInstallRequest
  ): Promise<ExtensionInstallOutcome> => {
    if (provider.status().extensionConnected) return installed(sessionId)
    if (!provider.status().chromeAvailable)
      throw new Error("Google Chrome isn't installed on the machine running this chat.")
    signal?.throwIfAborted()
    const limit = Math.min(
      EXTENSION_INSTALL_PROMPT_MS,
      (deadline ?? Infinity) - DEADLINE_MARGIN_MS - performance.now()
    )
    if (limit <= 0) return { outcome: "timeout" }
    const { promise: stopped, resolve: stop } = Promise.withResolvers<
      "connected" | "timeout" | "interrupted"
    >()
    const unsubscribe = provider.onExtensionConnectionChange((connected) => {
      if (connected) stop("connected")
    })
    const timer = setTimeout(() => stop("timeout"), limit)
    const interrupt = () => stop("interrupted")
    signal?.addEventListener("abort", interrupt, { once: true })
    try {
      let waiting = false
      while (true) {
        if (provider.status().extensionConnected) return installed(sessionId)
        const copy = extensionSetupCopy[setupMode()]
        const asked = await ask(sessionId, {
          id: "browser_preference",
          header: waiting ? "Finish in Chrome" : "Connect Chrome",
          question: copy.installQuestion,
          options: [copy.installOption],
          multiSelect: false,
          allowsOther: false,
          presentation: waiting ? "browserExtensionWaiting" : "browserExtensionSetup"
        })
        const result = await Promise.race([asked.answer, stopped])
        if (result === "connected") {
          await resolveQuestion(asked.questionId, "autoResolved")
          return installed(sessionId)
        }
        if (result === "timeout") {
          await resolveQuestion(asked.questionId, "cancelled")
          return { outcome: "timeout" }
        }
        if (result === "interrupted") {
          await resolveQuestion(asked.questionId, "cancelled")
          throw new Error("The Chrome extension prompt was interrupted before the user answered.")
        }
        if (result.outcome === "closed")
          throw new Error("The chat closed before the user answered the Chrome extension prompt.")
        if (result.outcome !== "answered") return { outcome: "dismissed" }
        const { label, note } = selectedAnswer(result)
        if (label !== copy.installOption.label)
          return { outcome: "dismissed", ...(note === undefined ? {} : { note }) }
        await openExtensionSetup()
        waiting = true
      }
    } finally {
      clearTimeout(timer)
      unsubscribe()
      signal?.removeEventListener("abort", interrupt)
    }
  }

  const permissionRequests = new Map<string, Promise<boolean>>()

  const askForComputerUsePermissions = async (
    sessionId: string,
    { signal, deadline }: ExtensionInstallRequest
  ): Promise<boolean> => {
    signal?.throwIfAborted()
    const limit = promptLimit(deadline)
    if (limit <= 0) return false

    const asked = await ask(sessionId, computerUsePermissionsQuestion)
    const result = await answerWithin(asked.answer, limit, signal)
    return settlePermissionAnswer(asked.questionId, result)
  }

  const settlePermissionAnswer = async (
    questionId: string,
    result: Settled | PromptStop
  ): Promise<boolean> => {
    if (result === "timeout" || result === "interrupted") {
      await resolveQuestion(questionId, "cancelled")
    }
    if (result === "timeout") return false
    if (result === "interrupted") throw new Error(permissionPromptInterrupted)
    if (result.outcome === "closed") throw new Error(permissionPromptClosed)

    return result.outcome === "answered"
  }

  const requestComputerUsePermissions = (
    sessionId: string,
    request: ExtensionInstallRequest
  ): Promise<boolean> => {
    const existing = permissionRequests.get(sessionId)
    if (existing !== undefined) return existing
    const created = askForComputerUsePermissions(sessionId, request).finally(() => {
      permissionRequests.delete(sessionId)
    })
    permissionRequests.set(sessionId, created)
    return created
  }

  return {
    beginTurn: (sessionId, options) => provider.beginTurn(sessionId, options),
    setSink: (sessionId, sink) => sinks.set(sessionId, sink),
    requestExtensionInstall,
    requestComputerUsePermissions,
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
    finishTurn: (sessionId) =>
      settlePending((current) => current.sessionId === sessionId, { outcome: "cancelled" }),
    closeSession: async (sessionId) => {
      await settlePending((current) => current.sessionId === sessionId, { outcome: "closed" })
      sinks.delete(sessionId)
    },
    close: async () => {
      await settlePending(() => true, { outcome: "closed" })
      sinks.clear()
    }
  }
}
