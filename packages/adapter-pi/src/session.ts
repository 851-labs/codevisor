import { randomUUID } from "node:crypto"

import {
  normalizePromptInput,
  withAttachmentNotes,
  type PromptInput,
  type QuestionAnswer,
  type RuntimeEmit
} from "@codevisor/agent-runtime"
import type { EventKind, SessionConfigOption } from "@codevisor/api"

import type { PiClient } from "./client.js"
import { makePiEventMapper } from "./events.js"
import {
  configOptions,
  MODEL_OPTION_ID,
  parseModelValue,
  THINKING_OPTION_ID,
  type PiModel
} from "./models.js"
import { dialogQuestion, type PiDialogQuestion } from "./questions.js"

/// One chat's Pi process: its state, turn lifecycle and controls.

/// The oldest Pi whose RPC mode has everything a chat needs.
export const MINIMUM_PI_VERSION = "0.81.0"

interface OpenQuestion {
  readonly dialogId: string
  readonly dialog: PiDialogQuestion
}

interface Turn {
  readonly id: string
  readonly initiatedBy: "user" | "agent"
  cancelled: boolean
  resolve?: (result: { stopReason: string }) => void
}

export interface PiSession {
  readonly key: string
  readonly configOptions: () => Array<SessionConfigOption>
  readonly prompt: (input: string | PromptInput) => Promise<{ stopReason: string }>
  readonly cancel: () => Promise<void>
  readonly setConfigOption: (configId: string, value: string) => Promise<Array<SessionConfigOption>>
  readonly answerQuestion: (questionId: string, answer: QuestionAnswer) => void
  readonly close: () => void
}

const record = (value: unknown): Record<string, unknown> =>
  typeof value === "object" && value !== null ? (value as Record<string, unknown>) : {}

const piModel = (value: unknown): PiModel | undefined => {
  const model = record(value)
  return typeof model.id === "string" && typeof model.provider === "string"
    ? (model as unknown as PiModel)
    : undefined
}

/// Pi's prompt: images inline, other attachments as path notes.
export const piPrompt = (input: PromptInput): Record<string, unknown> => {
  const attachments = input.attachments ?? []
  const images = attachments.flatMap((attachment) =>
    attachment.kind === "image" && attachment.inline !== undefined
      ? [
          {
            type: "image",
            data: attachment.inline.data.toString("base64"),
            mimeType: attachment.inline.mimeType
          }
        ]
      : []
  )
  const noted = attachments.filter(
    (attachment) => attachment.kind !== "image" || attachment.inline === undefined
  )
  return {
    message: withAttachmentNotes(input.text, noted),
    ...(images.length === 0 ? {} : { images })
  }
}

export const startPiSession = async (client: PiClient, emit: RuntimeEmit): Promise<PiSession> => {
  let models: ReadonlyArray<PiModel> = []
  let model: PiModel | undefined
  let levels: ReadonlyArray<string> = []
  let level: string | undefined
  let turn: Turn | undefined
  const questions = new Map<string, OpenQuestion>()
  const mapper = makePiEventMapper(() => model?.contextWindow)
  let key = ""

  const options = () => configOptions({ models, model, levels, level })
  const send = (kind: EventKind, payload: Record<string, unknown>) =>
    emit({ kind, payload, subjectId: key })

  const startTurn = (initiatedBy: "user" | "agent"): Turn => {
    const started: Turn = { id: randomUUID(), initiatedBy, cancelled: false }
    turn = started
    mapper.startRun()
    void send("session.updated", { initiatedBy, turnId: started.id, turnState: "started" })
    return started
  }

  const resolveQuestion = (questionId: string, open: OpenQuestion, answer: QuestionAnswer) => {
    questions.delete(questionId)
    client.respond({ id: open.dialogId, ...open.dialog.response(answer) })
    void send("session.output", {
      sessionUpdate: "question_resolved",
      questionId,
      outcome: answer.outcome,
      questions: [open.dialog.spec],
      ...(answer.answers === undefined ? {} : { answers: answer.answers })
    })
  }

  const endTurn = async (detail?: string): Promise<void> => {
    const ended = turn
    if (ended === undefined) return
    turn = undefined
    for (const [questionId, open] of questions)
      resolveQuestion(questionId, open, { outcome: "cancelled" })
    const outcome = mapper.outcome()
    const stopReason = ended.cancelled ? "cancelled" : "end_turn"
    const stopDetail =
      detail ??
      (ended.cancelled || outcome?.stopReason !== "error"
        ? undefined
        : (outcome.errorMessage ?? "Pi stopped with an error."))
    await send("session.updated", {
      initiatedBy: ended.initiatedBy,
      stopReason,
      ...(stopDetail === undefined ? {} : { stopDetail }),
      turnId: ended.id,
      turnState: "ended"
    })
    ended.resolve?.({ stopReason })
  }

  const ask = (request: Record<string, unknown>) => {
    const dialog = dialogQuestion(request)
    if (dialog === undefined || typeof request.id !== "string") return
    const questionId = randomUUID()
    questions.set(questionId, { dialogId: request.id, dialog })
    void send("session.output", {
      sessionUpdate: "question",
      questionId,
      ...(dialog.message === undefined ? {} : { message: dialog.message }),
      questions: [dialog.spec]
    })
  }

  client.onEvent((event) => {
    switch (event.type) {
      case "extension_ui_request":
        ask(event)
        return
      case "agent_start":
        // Pi can start work on its own (extension follow-ups, queued messages).
        if (turn === undefined) startTurn("agent")
        break
      case "thinking_level_changed":
        if (typeof event.level === "string") {
          level = event.level
          void send("session.updated", { configOptions: options() })
        }
        break
    }
    for (const mapped of mapper.map(event)) void send(mapped.kind, mapped.payload)
    if (event.type === "agent_settled") void endTurn()
  })
  client.onClose((error) => {
    void send("session.error", { message: error.message })
    void endTurn(error.message)
  })

  const state = record(await client.command("get_state"))
  key = String(state.sessionId)
  model = piModel(state.model)
  level = typeof state.thinkingLevel === "string" ? state.thinkingLevel : undefined
  const available = record(await client.command("get_available_models"))
  models = (Array.isArray(available.models) ? available.models : []).flatMap((entry) => {
    const parsed = piModel(entry)
    return parsed === undefined ? [] : [parsed]
  })
  const thinkingLevels = async (): Promise<ReadonlyArray<string>> => {
    const thinking = record(await client.command("get_available_thinking_levels"))
    return Array.isArray(thinking.levels)
      ? thinking.levels.filter((entry): entry is string => typeof entry === "string")
      : []
  }
  try {
    levels = await thinkingLevels()
  } catch (cause) {
    client.close()
    throw new Error(
      `This version of Pi is too old for Codevisor. Update Pi to ${MINIMUM_PI_VERSION} or newer.`,
      { cause }
    )
  }

  return {
    key,
    configOptions: options,
    prompt: async (input) => {
      const started = startTurn("user")
      const finished = new Promise<{ stopReason: string }>((resolve) => {
        started.resolve = resolve
      })
      try {
        const accepted = record(
          await client.command("prompt", piPrompt(normalizePromptInput(input)))
        )
        // An extension command can handle the prompt without starting a run.
        if (accepted.disposition === "handled") await endTurn()
      } catch (cause) {
        // The client rejects with Pi's error.
        await endTurn((cause as Error).message)
      }
      return finished
    },
    cancel: async () => {
      if (turn !== undefined) turn.cancelled = true
      await client.command("abort")
    },
    setConfigOption: async (configId, value) => {
      if (configId === MODEL_OPTION_ID) {
        const target = parseModelValue(value)
        if (target === undefined) throw new Error(`Unknown model: ${value}`)
        model = piModel(await client.command("set_model", target)) ?? model
        // Thinking levels depend on the model.
        levels = await thinkingLevels()
        level = String(record(await client.command("get_state")).thinkingLevel ?? level)
      } else if (configId === THINKING_OPTION_ID) {
        await client.command("set_thinking_level", { level: value })
        level = value
      } else {
        throw new Error(`Pi has no setting named ${configId}`)
      }
      return options()
    },
    answerQuestion: (questionId, answer) => {
      const open = questions.get(questionId)
      if (open === undefined) throw new Error(`No pending question: ${questionId}`)
      resolveQuestion(questionId, open, answer)
    },
    close: () => client.close()
  }
}
