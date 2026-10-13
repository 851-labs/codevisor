import { randomUUID } from "node:crypto"

import {
  normalizePromptInput,
  skillsUpdateEvent,
  type PromptInput,
  type QuestionAnswer,
  type RuntimeEmit,
  type ToolGatewayConfig
} from "@codevisor/agent-runtime"
import type { EventKind, SessionConfigOption, SessionSkills } from "@codevisor/api"

import { MuseRequestError, type MuseClient } from "./client.js"
import { makeMuseItemMapper } from "./items.js"
import { configOptions, EFFORT_OPTION_ID, MODEL_OPTION_ID, modelTiers } from "./models.js"
import {
  commandId,
  record,
  text,
  type ApprovalRequest,
  type ModelCatalogEntry,
  type MuseItem,
  type MuseSession as MuseSessionRecord,
  type UserInputRequest
} from "./protocol.js"
import { approvalQuestion, userInputQuestion, type MuseQuestion } from "./questions.js"
import { makeMuseSubagents, type ViewPage } from "./subagents.js"
import {
  contextUsageUpdate,
  museSkills,
  planUpdate,
  tokenUsageUpdate,
  turnInput
} from "./updates.js"

/// One chat's `muse serve` host: its session, turn lifecycle and controls.

interface Turn {
  readonly id: string
  readonly initiatedBy: "user" | "agent"
  /// Muse's id for the turn: the submitting command id for a prompt.
  museTurnId: string | undefined
  cancelled: boolean
  resolve?: (result: { stopReason: string }) => void
}

export interface MuseChat {
  readonly key: string
  readonly configOptions: () => Array<SessionConfigOption>
  readonly skills: SessionSkills | undefined
  readonly prompt: (input: string | PromptInput) => Promise<{ stopReason: string }>
  readonly cancel: () => Promise<void>
  readonly setConfigOption: (configId: string, value: string) => Promise<Array<SessionConfigOption>>
  readonly answerQuestion: (questionId: string, answer: QuestionAnswer) => Promise<void>
  readonly close: () => void
}

export interface MuseChatOptions {
  readonly cwd: string
  /// The Muse session to resume; a new session when absent.
  readonly resume?: string
  readonly toolGateway?: ToolGatewayConfig
}

/// Codevisor's MCP tool gateway, as a session-scoped MCP server.
const sessionConfig = (gateway: ToolGatewayConfig | undefined) =>
  gateway === undefined
    ? {}
    : {
        config: {
          mcpServers: {
            [gateway.name]: {
              transport: "streamableHttp",
              url: gateway.url,
              headers: { Authorization: `Bearer ${gateway.bearerToken}` },
              mode: "optional"
            }
          }
        }
      }

const stopDetail = (
  error: Record<string, unknown>,
  reason: string | undefined
): string | undefined =>
  error.kind === "authRequired"
    ? "Sign in to Muse Code to continue."
    : (text(error.message) ?? reason)

export const startMuseChat = async (
  client: MuseClient,
  emit: RuntimeEmit,
  options: MuseChatOptions
): Promise<MuseChat> => {
  let key = options.resume ?? ""
  let models: ReadonlyArray<ModelCatalogEntry> = []
  let modelId: string | undefined
  let effort: string | undefined
  let skills: SessionSkills | undefined
  let turn: Turn | undefined
  const questions = new Map<string, MuseQuestion>()
  const mapper = makeMuseItemMapper(() => key)
  const subagents = makeMuseSubagents({
    page: async (sessionId, cursor) =>
      record(
        await client.request("view/page", {
          sessionId,
          limit: 1000,
          ...(cursor === undefined ? {} : { cursor })
        })
      ) as unknown as ViewPage,
    send: (event) => void send(event.kind, event.payload)
  })

  const current = () => models.find((model) => model.modelId === modelId)
  const options_ = () => configOptions({ models, modelId, effort })
  const send = (kind: EventKind, payload: Record<string, unknown>) =>
    emit({ kind, payload, subjectId: key })
  const announceOptions = () => void send("session.updated", { configOptions: options_() })

  const startTurn = (initiatedBy: "user" | "agent", museTurnId?: string): Turn => {
    const started: Turn = { id: randomUUID(), initiatedBy, museTurnId, cancelled: false }
    turn = started
    void send("session.updated", { initiatedBy, turnId: started.id, turnState: "started" })
    return started
  }

  const resolved = (
    questionId: string,
    question: MuseQuestion,
    answer: QuestionAnswer | { outcome: "autoResolved" }
  ) =>
    send("session.output", {
      sessionUpdate: "question_resolved",
      questionId,
      outcome: answer.outcome,
      questions: question.specs,
      ...("answers" in answer && answer.answers !== undefined ? { answers: answer.answers } : {})
    })

  const endTurn = async (outcome: {
    detail?: string
    retryable?: boolean
    cancelled?: boolean
  }) => {
    const ended = turn
    if (ended === undefined) return
    turn = undefined
    // Muse settles a turn's open asks itself; any left belong to it.
    for (const [questionId, question] of questions)
      void resolved(questionId, question, { outcome: "cancelled" })
    questions.clear()
    const stopReason = ended.cancelled || outcome.cancelled === true ? "cancelled" : "end_turn"
    await send("session.updated", {
      initiatedBy: ended.initiatedBy,
      stopReason,
      ...(outcome.detail === undefined ? {} : { stopDetail: outcome.detail }),
      ...(outcome.retryable === true ? { retryable: true } : {}),
      turnId: ended.id,
      turnState: "ended"
    })
    ended.resolve?.({ stopReason })
  }

  const ask = (id: string, question: MuseQuestion) => {
    const replaced = questions.get(id)
    // A multi-stage approval re-asks under the same id with new choices.
    if (replaced !== undefined) void resolved(id, replaced, { outcome: "autoResolved" })
    questions.set(id, question)
    void send("session.output", {
      sessionUpdate: "question",
      questionId: id,
      ...(question.autoResolutionMs === undefined
        ? {}
        : { autoResolutionMs: question.autoResolutionMs }),
      questions: question.specs
    })
  }

  /// A question Muse settled on its own (auto-resolution, another client).
  const settledElsewhere = (id: unknown) => {
    const question = typeof id === "string" ? questions.get(id) : undefined
    if (question === undefined) return
    questions.delete(id as string)
    void resolved(id as string, question, { outcome: "autoResolved" })
  }

  /// Only the newest listing publishes: an older, slower one never
  /// announces a list a newer one already replaced.
  let skillListings = 0
  const listSkills = async (): Promise<SessionSkills | undefined> => {
    try {
      return museSkills(await client.request("skill/list", { sessionId: key }))
    } catch {
      return undefined
    }
  }

  client.onRequest((method, params) => {
    if (method === "approval/request") {
      const request = params as ApprovalRequest
      ask(request.approvalId, approvalQuestion(request))
    } else if (method === "userInput/request") {
      const request = params as UserInputRequest
      ask(request.userInputId, userInputQuestion(request))
    }
    return {}
  })

  client.onNotification((method, params) => {
    const event = record(params)
    // Child sessions (subagents, reminders) report on their own ids.
    if (typeof event.sessionId === "string" && key !== "" && event.sessionId !== key) return
    switch (method) {
      case "turn/started":
        if (turn === undefined) startTurn("agent", text(event.turnId))
        else turn.museTurnId ??= text(event.turnId)
        return
      case "turn/completed":
      case "turn/unqueued": {
        if (
          turn === undefined ||
          (turn.museTurnId !== undefined && turn.museTurnId !== event.turnId)
        )
          return
        const error = record(event.error)
        const finish = () =>
          void endTurn({
            ...(event.terminal === "cancelled" ? { cancelled: true } : {}),
            ...(event.terminal === "failed"
              ? { detail: stopDetail(error, text(event.reason)) ?? "Muse stopped with an error." }
              : {}),
            ...(error.retryable === true ? { retryable: true } : {})
          })
        // A subagent's last steps land in its thread before the turn ends.
        const draining = subagents.drain()
        if (draining === undefined) finish()
        else void draining.then(finish)
        return
      }
      case "item/started":
      case "item/updated":
      case "item/completed": {
        const item = record(event.item) as unknown as MuseItem
        if (typeof item.itemId !== "string") return
        const edge = method.slice("item/".length) as "started" | "updated" | "completed"
        for (const mapped of mapper.item(item, edge)) void send(mapped.kind, mapped.payload)
        subagents.observe(item, mapper.runRow)
        return
      }
      case "item/delta":
        if (typeof event.itemId !== "string" || typeof event.delta !== "string") return
        for (const mapped of mapper.delta(event.itemId, text(event.field) ?? "text", event.delta))
          void send(mapped.kind, mapped.payload)
        return
      case "session/tokenUsage":
        void send("session.updated", tokenUsageUpdate(event))
        return
      case "session/contextUsage":
        void send("session.updated", contextUsageUpdate(event))
        return
      case "session/todoListChanged":
        void send("session.output", planUpdate(event))
        return
      case "session/nameChanged":
        if (text(event.name) !== undefined)
          void send("session.updated", { sessionUpdate: "session_info_update", title: event.name })
        return
      case "session/modelChanged":
        if (text(event.modelId) === undefined) return
        modelId = event.modelId as string
        if (effort !== undefined && !modelTiers(current()).includes(effort)) effort = undefined
        announceOptions()
        return
      case "session/reasoningEffortChanged":
        if (text(event.reasoningEffort) === undefined) return
        effort = event.reasoningEffort as string
        announceOptions()
        return
      case "skill/changed":
        const listing = ++skillListings
        void listSkills().then((listed) => {
          if (listed === undefined || listing !== skillListings) return
          skills = listed
          void emit(skillsUpdateEvent(key, listed))
        })
        return
      case "approval/resolved":
        settledElsewhere(event.approvalId)
        return
      case "userInput/settled":
        settledElsewhere(event.userInputId)
        return
    }
  })

  client.onClose((error) => {
    void send("session.error", { message: error.message })
    void endTurn({ detail: error.message })
  })

  const config = sessionConfig(options.toolGateway)
  let session: MuseSessionRecord
  if (options.resume === undefined) {
    session = record(
      await client.request("session/start", {
        commandId: commandId(),
        workspaceRoot: options.cwd,
        // Codevisor runs every harness with full access (see adapter-acp's
        // permission policy); Muse still escalates what its reviewer flags.
        approvalMode: "allowAll",
        ...config
      })
    ).session as MuseSessionRecord
  } else {
    const resume = (extra: Record<string, unknown>) =>
      client.request("session/resume", {
        commandId: commandId(),
        sessionId: options.resume,
        excludeItems: true,
        ...extra
      })
    let resumed: unknown
    try {
      resumed = await resume(config)
    } catch (cause) {
      // A session keeps the MCP servers it started with; a new gateway
      // credential conflicts with the old one, so resume without it.
      if (!(cause instanceof MuseRequestError) || !/configuration_conflict/.test(cause.message))
        throw cause
      resumed = await resume({})
    }
    session = record(resumed).session as MuseSessionRecord
    // A session started elsewhere (the Muse CLI) keeps its own approval
    // mode; Codevisor's chats all run with full access.
    await client
      .request("session/setApprovalMode", {
        commandId: commandId(),
        sessionId: session.sessionId,
        mode: "allowAll"
      })
      .catch(() => undefined)
  }
  key = session.sessionId
  modelId = session.modelId ?? undefined

  try {
    const listed = record(await client.request("model/list", { sessionId: key }))
    models = Array.isArray(listed.models) ? (listed.models as Array<ModelCatalogEntry>) : []
  } catch {
    models = []
  }
  modelId ??= models.find((model) => model.isActive)?.modelId
  skills = await listSkills()

  return {
    key,
    configOptions: options_,
    skills,
    prompt: async (input) => {
      // Muse queues a prompt sent mid-turn behind the running one; the turn
      // Codevisor was tracking ends here so its caller isn't left waiting.
      await endTurn({})
      const command = commandId()
      const started = startTurn("user", command)
      const finished = new Promise<{ stopReason: string }>((resolve) => {
        started.resolve = resolve
      })
      try {
        const accepted = record(
          await client.request("turn/start", {
            commandId: command,
            sessionId: key,
            input: turnInput(normalizePromptInput(input), skills?.skills ?? [])
          })
        )
        if (typeof accepted.turnId === "string") started.museTurnId = accepted.turnId
      } catch (cause) {
        await endTurn({
          detail:
            cause instanceof MuseRequestError && cause.kind === "authRequired"
              ? "Sign in to Muse Code to continue."
              : (cause as Error).message
        })
      }
      return finished
    },
    cancel: async () => {
      if (turn === undefined) return
      turn.cancelled = true
      await client.request("turn/interrupt", {
        commandId: commandId(),
        sessionId: key,
        ...(turn.museTurnId === undefined ? {} : { turnId: turn.museTurnId })
      })
    },
    setConfigOption: async (configId, value) => {
      if (configId === MODEL_OPTION_ID) {
        const model = models.find((entry) => entry.modelId === value)
        if (model === undefined) throw new Error(`Unknown model: ${value}`)
        await client.request("session/setModel", {
          commandId: commandId(),
          sessionId: key,
          model: {
            modelId: model.modelId,
            providerId: model.providerId,
            profileId: model.profileId
          }
        })
        modelId = model.modelId
        if (effort !== undefined && !modelTiers(model).includes(effort)) effort = undefined
      } else if (configId === EFFORT_OPTION_ID) {
        if (!modelTiers(current()).includes(value))
          throw new Error(`Unknown reasoning level: ${value}`)
        await client.request("session/setReasoningEffort", {
          commandId: commandId(),
          sessionId: key,
          reasoningEffort: value
        })
        effort = value
      } else {
        throw new Error(`Muse Code has no setting named ${configId}`)
      }
      return options_()
    },
    answerQuestion: async (questionId, answer) => {
      const question = questions.get(questionId)
      if (question === undefined) throw new Error(`No pending question: ${questionId}`)
      questions.delete(questionId)
      const reply = question.reply(answer)
      try {
        await client.request(reply.method, reply.params)
      } catch (cause) {
        // Muse is still waiting on it: the user can answer again.
        questions.set(questionId, question)
        throw cause
      }
      await resolved(questionId, question, answer)
    },
    close: () => {
      subagents.stop()
      void endTurn({ cancelled: true })
      client.close()
    }
  }
}
