import { randomUUID } from "node:crypto"

import {
  answersIfPresent,
  normalizePromptInput,
  sessionUpdateFirstPayloads,
  skillsUpdateEvent,
  type PromptInput,
  type QuestionAnswer,
  type QuestionResolution,
  type RuntimeEmit,
  type ToolGatewayConfig
} from "@codevisor/agent-runtime"
import type { EventKind, SessionConfigOption, SessionSkills } from "@codevisor/api"

import { MuseRequestError, type MuseClient } from "./client.js"
import { makeMuseItemMapper } from "./items.js"
import { configOptions, EFFORT_OPTION_ID, MODEL_OPTION_ID, modelTiers } from "./models.js"
import {
  commandId,
  messageOf,
  record,
  string,
  text,
  type ModelCatalogEntry,
  type MuseSession as MuseSessionRecord
} from "./protocol.js"
import { approvalQuestion, userInputQuestion, type MuseQuestion } from "./questions.js"
import { itemEdge } from "./rows.js"
import { makeMuseSubagents } from "./subagents.js"
import { completedOutcome, signedOutOutcome, type TurnOutcome } from "./turn-outcomes.js"
import {
  contextUsageUpdate,
  museSkills,
  planUpdate,
  tokenUsageUpdate,
  turnInput
} from "./updates.js"
import { observeMuseUsageLimits } from "./usage.js"
import {
  approvalRequest,
  modelCatalog,
  museItem,
  requireSession,
  userInputRequest
} from "./wire.js"

const questionPayloads = sessionUpdateFirstPayloads(answersIfPresent)

interface Turn {
  readonly id: string
  readonly initiatedBy: "user" | "agent"
  museTurnId: string | undefined
  cancelled: boolean
  foregroundDone: boolean
  resolve?: (result: { stopReason: string }) => void
}

export interface MuseChat {
  readonly key: string
  readonly configOptions: () => Array<SessionConfigOption>
  readonly skills: SessionSkills | undefined
  readonly prompt: (input: string | PromptInput) => Promise<{ stopReason: string }>
  readonly steer: (input: string | PromptInput) => Promise<boolean>
  readonly cancel: () => Promise<void>
  readonly setConfigOption: (configId: string, value: string) => Promise<Array<SessionConfigOption>>
  readonly answerQuestion: (questionId: string, answer: QuestionAnswer) => Promise<void>
  readonly close: () => void
}

export interface MuseChatOptions {
  readonly cwd: string
  readonly resume?: string
  readonly toolGateway?: ToolGatewayConfig
}

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
    page: (sessionId, cursor) =>
      client.request("view/page", {
        sessionId,
        limit: 1000,
        ...(cursor === undefined ? {} : { cursor })
      }),
    send: (event) => void send(event.kind, event.payload)
  })

  const current = () => models.find((model) => model.modelId === modelId)
  const museInput = (input: string | PromptInput) =>
    turnInput(normalizePromptInput(input), skills?.skills ?? [])
  const currentOptions = () => configOptions({ models, modelId, effort })
  const send = (kind: EventKind, payload: object) => emit({ kind, payload, subjectId: key })
  const announceOptions = () => void send("session.updated", { configOptions: currentOptions() })

  const startTurn = (initiatedBy: "user" | "agent", museTurnId?: string): Turn => {
    const started: Turn = {
      id: randomUUID(),
      initiatedBy,
      museTurnId,
      cancelled: false,
      foregroundDone: false
    }
    turn = started
    void send("session.updated", { initiatedBy, turnId: started.id, turnState: "started" })
    return started
  }

  const resolved = (questionId: string, question: MuseQuestion, resolution: QuestionResolution) =>
    send("session.output", questionPayloads.resolved(questionId, question.specs, resolution))

  const endTurn = async (outcome: TurnOutcome) => {
    const ended = turn
    if (ended === undefined) return
    turn = undefined
    for (const [questionId, question] of questions)
      void resolved(questionId, question, { outcome: "cancelled" })
    questions.clear()
    const stopReason = ended.cancelled || outcome.cancelled === true ? "cancelled" : "end_turn"
    await send("session.updated", {
      initiatedBy: ended.initiatedBy,
      stopReason,
      ...(outcome.stopDetail === undefined ? {} : { stopDetail: outcome.stopDetail }),
      ...(outcome.stopKind === undefined ? {} : { stopKind: outcome.stopKind }),
      ...(outcome.resetsAt === undefined ? {} : { resetsAt: outcome.resetsAt }),
      ...(outcome.retryable === true ? { retryable: true } : {}),
      turnId: ended.id,
      turnState: "ended"
    })
    ended.resolve?.({ stopReason })
  }

  const ask = (id: string, question: MuseQuestion) => {
    const replaced = questions.get(id)
    if (replaced !== undefined) void resolved(id, replaced, { outcome: "autoResolved" })
    questions.set(id, question)
    void send(
      "session.output",
      questionPayloads.asked(id, question.specs, {
        autoResolutionMs: question.autoResolutionMs
      })
    )
  }

  const settledElsewhere = (value: unknown) => {
    const id = string(value)
    if (id === undefined) return
    const question = questions.get(id)
    if (question === undefined) return
    questions.delete(id)
    void resolved(id, question, { outcome: "autoResolved" })
  }

  let skillListings = 0
  const listSkills = async (): Promise<SessionSkills | undefined> => {
    try {
      return museSkills(await client.request("skill/list", { sessionId: key }))
    } catch {
      return undefined
    }
  }

  client.onRequest((method, params) => {
    const approval = method === "approval/request" ? approvalRequest(params) : undefined
    const input = method === "userInput/request" ? userInputRequest(params) : undefined
    if (approval !== undefined) ask(approval.approvalId, approvalQuestion(approval))
    if (input !== undefined) ask(input.userInputId, userInputQuestion(input))
    return {}
  })

  client.onNotification((method, params) => {
    const event = record(params)
    if (typeof event.sessionId === "string" && key !== "" && event.sessionId !== key) return
    const edge = itemEdge(method)
    if (edge !== undefined) {
      const item = museItem(event.item)
      if (item === undefined) return
      for (const mapped of mapper.item(item, edge)) void send(mapped.kind, mapped.payload)
      subagents.observe(item, mapper.runRow)
      return
    }
    switch (method) {
      case "turn/started":
        if (turn === undefined) startTurn("agent", text(event.turnId))
        else turn.museTurnId ??= text(event.turnId)
        return
      case "turn/foregroundCompleted":
        if (turn !== undefined && turn.museTurnId === event.turnId) turn.foregroundDone = true
        return
      case "turn/completed":
      case "turn/unqueued": {
        if (
          turn === undefined ||
          (turn.museTurnId !== undefined && turn.museTurnId !== event.turnId)
        )
          return
        const finish = () => void endTurn(completedOutcome(event))
        const draining = subagents.drain()
        if (draining === undefined) finish()
        else void draining.then(finish)
        void observeMuseUsageLimits(client, key, emit)
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
      case "session/modelChanged": {
        const changed = text(event.modelId)
        if (changed === undefined) return
        modelId = changed
        if (effort !== undefined && !modelTiers(current()).includes(effort)) effort = undefined
        announceOptions()
        return
      }
      case "session/reasoningEffortChanged": {
        const changed = text(event.reasoningEffort)
        if (changed === undefined) return
        effort = changed
        announceOptions()
        return
      }
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
    void endTurn({ stopDetail: error.message })
  })

  const config = sessionConfig(options.toolGateway)
  let session: MuseSessionRecord
  if (options.resume === undefined) {
    session = requireSession(
      await client.request("session/start", {
        commandId: commandId(),
        workspaceRoot: options.cwd,
        approvalMode: "allowAll",
        ...config
      })
    )
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
      if (!(cause instanceof MuseRequestError) || !/configuration_conflict/.test(cause.message))
        throw cause
      resumed = await resume({})
    }
    session = requireSession(resumed)
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
    models = modelCatalog(listed.models)
  } catch {
    models = []
  }
  modelId ??= models.find((model) => model.isActive)?.modelId
  skills = await listSkills()

  return {
    key,
    configOptions: currentOptions,
    skills,
    prompt: async (input) => {
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
            input: museInput(input)
          })
        )
        if (typeof accepted.turnId === "string") started.museTurnId = accepted.turnId
      } catch (cause) {
        const signedOut = cause instanceof MuseRequestError && cause.kind === "authRequired"
        await endTurn(signedOut ? signedOutOutcome : { stopDetail: messageOf(cause) })
      }
      return finished
    },
    steer: async (input) => {
      const running = turn
      if (
        running === undefined ||
        running.cancelled ||
        running.foregroundDone ||
        running.museTurnId === undefined
      )
        return false
      try {
        const accepted = record(
          await client.request("turn/steer", {
            commandId: commandId(),
            sessionId: key,
            expectedTurnId: running.museTurnId,
            input: museInput(input)
          })
        )
        return accepted.turnId === running.museTurnId
      } catch (cause) {
        if (cause instanceof MuseRequestError) return false
        throw cause
      }
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
      return currentOptions()
    },
    answerQuestion: async (questionId, answer) => {
      const question = questions.get(questionId)
      if (question === undefined) throw new Error(`No pending question: ${questionId}`)
      questions.delete(questionId)
      const reply = question.reply(answer)
      try {
        await client.request(reply.method, reply.params)
      } catch (cause) {
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
