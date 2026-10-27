import { randomUUID } from "node:crypto"

import type { QuestionAnswer } from "@codevisor/agent-runtime"
import type { PluginSetupRequest, QuestionSpec } from "@codevisor/api"

import { HttpFailure } from "../../server-context.js"
import {
  authOf,
  capabilitiesOf,
  type PluginDirectory,
  type PluginTarget
} from "./plugin-directory.js"

export type PluginSetupOutcomeKind = "connected" | "declined" | "pending"

export interface PluginSetupOutcome {
  readonly outcome: PluginSetupOutcomeKind
  readonly plugin: string
  readonly name: string
  readonly accounts: ReadonlyArray<string>
}

export interface PluginSetupInput {
  readonly sessionId: string
  readonly plugin: string
  readonly reason: string
  readonly waitMs: number
}

export interface PluginSetupBroker {
  readonly request: (input: PluginSetupInput) => Promise<PluginSetupOutcome>
  readonly answer: (
    sessionId: string,
    questionId: string,
    answer: QuestionAnswer
  ) => Promise<boolean>
  readonly refresh: () => Promise<void>
}

export interface PluginSetupDeps {
  readonly directory: PluginDirectory
  readonly emit: (sessionId: string, payload: unknown) => Promise<void>
  readonly machine: { readonly id: string; readonly name: string }
  readonly wait: (ms: number) => Promise<void>
}

export const setupQuestionId = "plugin_setup"

export const makePluginSetupBroker = (deps: PluginSetupDeps): PluginSetupBroker => {
  const pending = new Map<string, PendingSetup>()

  const settle = async (
    questionId: string,
    kind: PluginSetupOutcomeKind,
    outcome: "autoResolved" | "cancelled"
  ) => {
    const entry = pending.get(questionId)
    if (entry === undefined) return
    pending.delete(questionId)
    await deps
      .emit(entry.sessionId, resolvedPayload(questionId, entry.question, outcome))
      .catch(() => undefined)
    entry.settle(kind)
  }

  const askOrReuse = async (
    input: PluginSetupInput,
    target: PluginTarget
  ): Promise<PendingSetup> => {
    const existing = [...pending.values()].find(
      (entry) => entry.sessionId === input.sessionId && entry.plugin === target.plugin
    )
    if (existing !== undefined) return existing
    const entry = newPendingSetup(input, target, deps.machine)
    pending.set(entry.questionId, entry)
    await deps.emit(input.sessionId, {
      sessionUpdate: "question",
      questionId: entry.questionId,
      questions: [entry.question]
    })
    return entry
  }

  const itemOf = async (plugin: string) => {
    const target = await deps.directory.find(plugin)
    if (target === undefined) return undefined
    return deps.directory.item(target)
  }

  const outcomeOf = async (
    plugin: string,
    kind: PluginSetupOutcomeKind
  ): Promise<PluginSetupOutcome> => {
    const item = await itemOf(plugin)
    return {
      outcome: kind,
      plugin: item?.plugin ?? plugin,
      name: item?.name ?? plugin,
      accounts: item?.accounts ?? []
    }
  }

  return {
    request: async (input) => {
      const target = await requireTarget(deps.directory, input.plugin)
      if ((await deps.directory.item(target)).ready) return outcomeOf(input.plugin, "connected")
      const entry = await askOrReuse(input, target)
      const kind = await Promise.race([
        entry.done,
        deps.wait(input.waitMs).then(() => "pending" as const)
      ])
      return outcomeOf(input.plugin, kind)
    },
    answer: async (sessionId, questionId, answer) => {
      const entry = pending.get(questionId)
      if (entry === undefined || entry.sessionId !== sessionId) return false
      if (isDecline(answer)) await settle(questionId, "declined", "cancelled")
      return true
    },
    refresh: async () => {
      for (const entry of pending.values()) {
        const target = await deps.directory.find(entry.plugin)
        if (target === undefined || !(await deps.directory.item(target)).ready) continue
        await settle(entry.questionId, "connected", "autoResolved")
      }
    }
  }
}

interface PendingSetup {
  readonly questionId: string
  readonly sessionId: string
  readonly plugin: string
  readonly question: QuestionSpec
  readonly done: Promise<PluginSetupOutcomeKind>
  readonly settle: (kind: PluginSetupOutcomeKind) => void
}

const newPendingSetup = (
  input: PluginSetupInput,
  target: PluginTarget,
  machine: { readonly id: string; readonly name: string }
): PendingSetup => {
  const { promise, resolve } = Promise.withResolvers<PluginSetupOutcomeKind>()
  return {
    questionId: `plugin-setup:${randomUUID()}`,
    sessionId: input.sessionId,
    plugin: target.plugin,
    question: setupQuestion(setupRequest(input, target, machine)),
    done: promise,
    settle: resolve
  }
}

const setupRequest = (
  input: PluginSetupInput,
  target: PluginTarget,
  machine: { readonly id: string; readonly name: string }
): PluginSetupRequest => ({
  plugin: target.plugin,
  ...(target.entry === undefined
    ? {}
    : {
        catalogId: target.entry.id,
        publisher: target.entry.publisher,
        description: target.entry.description
      }),
  ...(target.server === undefined ? {} : { serverId: target.server.id }),
  name: target.server?.name ?? target.entry!.name,
  reason: input.reason,
  auth: authOf(target),
  capabilities: capabilitiesOf(target),
  machine
})

const setupQuestion = (request: PluginSetupRequest): QuestionSpec => ({
  id: setupQuestionId,
  header: request.name,
  question: request.reason,
  options: [{ label: "Set Up" }, { label: "Not Now" }],
  multiSelect: false,
  allowsOther: false,
  presentation: "pluginSetup",
  pluginSetup: request
})

const resolvedPayload = (
  questionId: string,
  question: QuestionSpec,
  outcome: "autoResolved" | "cancelled"
) => ({
  sessionUpdate: "question_resolved",
  questionId,
  questions: [question],
  outcome
})

const isDecline = (answer: QuestionAnswer): boolean =>
  answer.outcome === "cancelled" ||
  answer.answers?.[setupQuestionId]?.answers.includes("Not Now") === true

const requireTarget = async (directory: PluginDirectory, plugin: string): Promise<PluginTarget> => {
  const target = await directory.find(plugin)
  if (target !== undefined) return target
  throw new HttpFailure(404, `No plugin named "${plugin}". Search with plugins.search.`)
}
