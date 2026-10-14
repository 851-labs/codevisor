import { randomUUID } from "node:crypto"

import {
  normalizePromptInput,
  withAttachmentNotes,
  type PromptInput,
  type RuntimeEmit
} from "@codevisor/agent-runtime"
import type { EventKind, SessionConfigOption } from "@codevisor/api"

import type { AgyConnector, AgyProcess } from "./client.js"
import { makeAgyStepMapper } from "./items.js"
import {
  configOptions,
  EFFORT_OPTION_ID,
  MODEL_OPTION_ID,
  resolveSelection,
  type AgyModel
} from "./models.js"
import {
  finite,
  record,
  signedOut,
  SIGN_IN_DETAIL,
  text,
  type AgyResult,
  type AgyStep
} from "./protocol.js"

/// One chat's `agy` headless process: its conversation, turn lifecycle and
/// controls. agy fixes the model for a process's lifetime, so a new model or
/// reasoning tier — like a cancelled turn that took the process down —
/// relaunches it on the same conversation at the next prompt.

interface Turn {
  readonly id: string
  cancelled: boolean
  resolve: (result: { stopReason: string }) => void
}

export interface AgyChat {
  readonly key: string
  readonly configOptions: () => Array<SessionConfigOption>
  readonly prompt: (input: string | PromptInput) => Promise<{ stopReason: string }>
  readonly cancel: () => Promise<void>
  readonly setConfigOption: (configId: string, value: string) => Promise<Array<SessionConfigOption>>
  readonly close: () => void
}

export interface AgyChatOptions {
  readonly connector: AgyConnector
  readonly command: string
  readonly cwd: string
  readonly env: NodeJS.ProcessEnv
  /// Arguments every launch carries (account isolation).
  readonly extraArgs?: ReadonlyArray<string>
  readonly models: ReadonlyArray<AgyModel>
  /// The conversation to resume; a new one when absent.
  readonly resume?: string
  /// How long agy may take to open its conversation.
  readonly startDeadlineMs?: number
  /// How long a cancelled turn may take to stop before agy is killed.
  readonly cancelGraceMs?: number
}

/// How every chat runs. Codevisor gives every harness full access (see
/// adapter-acp's permission policy), and headless agy can't ask for
/// permission, so it proceeds on its own; Codevisor decides when a turn
/// ends.
const HEADLESS_ARGS = [
  "--input-format=stream-json",
  "--output-format=stream-json",
  "--print-timeout=0",
  "--dangerously-skip-permissions"
]

class AgyStartError extends Error {}

/// Why agy stopped a turn, in words the transcript can show.
const failureDetail = (message: string | undefined): string =>
  message === undefined
    ? "Antigravity stopped with an error."
    : signedOut(message)
      ? SIGN_IN_DETAIL
      : message

/// `result.usage` is the session's running totals.
const totalsUpdate = (result: AgyResult): Record<string, unknown> | undefined => {
  const usage = record(result.usage)
  const fields = Object.entries({
    inputTokens: finite(usage.input_tokens),
    outputTokens: finite(usage.output_tokens),
    totalTokens: finite(usage.total_tokens),
    cachedInputTokens: finite(usage.cache_read_tokens),
    reasoningOutputTokens: finite(usage.thinking_tokens)
  }).filter((entry): entry is [string, number] => entry[1] !== undefined)
  return fields.length === 0
    ? undefined
    : { sessionUpdate: "usage_update", ...Object.fromEntries(fields) }
}

export const startAgyChat = async (
  emit: RuntimeEmit,
  options: AgyChatOptions
): Promise<AgyChat> => {
  const startDeadlineMs = options.startDeadlineMs ?? 60_000
  const cancelGraceMs = options.cancelGraceMs ?? 5_000
  let key = options.resume ?? ""
  const selection: { modelId?: string | undefined; tier?: string | undefined } = {}
  const resolved = resolveSelection(options.models, selection)
  if (resolved !== undefined) {
    selection.modelId = resolved.model.id
    selection.tier = resolved.variant.tier
  }
  let process_: AgyProcess | undefined
  /// The running process predates the chosen model or tier.
  let stale = false
  let turn: Turn | undefined
  let cancelTimer: ReturnType<typeof setTimeout> | undefined
  let queue: Promise<unknown> = Promise.resolve()
  const mapper = makeAgyStepMapper(() => key)

  const send = (kind: EventKind, payload: Record<string, unknown>) =>
    emit({ kind, payload, subjectId: key })
  const options_ = () => configOptions(options.models, selection)

  const endTurn = (outcome: { detail?: string; cancelled?: boolean }) => {
    const ended = turn
    if (ended === undefined) return
    turn = undefined
    clearTimeout(cancelTimer)
    const stopReason = ended.cancelled || outcome.cancelled === true ? "cancelled" : "end_turn"
    void send("session.updated", {
      initiatedBy: "user",
      stopReason,
      ...(outcome.detail === undefined || stopReason === "cancelled"
        ? {}
        : { stopDetail: outcome.detail }),
      turnId: ended.id,
      turnState: "ended"
    })
    ended.resolve({ stopReason })
  }

  const finished = (result: AgyResult) => {
    const totals = totalsUpdate(result)
    if (totals !== undefined) void send("session.updated", totals)
    if (result.status === "SUCCESS") {
      // Headless agy skips what it can't ask permission for, and says so.
      const denied = (result.denied_actions ?? []).flatMap((action) => {
        const name = text(action.display_name) ?? text(action.action)
        return name === undefined ? [] : [name]
      })
      endTurn(
        denied.length === 0
          ? {}
          : {
              detail: `Antigravity skipped actions it needed permission for: ${denied.join(", ")}.`
            }
      )
    } else if (result.status === "CANCELED" || result.status === "INTERRUPTED") {
      endTurn({ cancelled: true })
    } else {
      endTurn({ detail: failureDetail(text(result.error)) })
    }
  }

  const handle = (event: Record<string, unknown>) => {
    if (event.event === "step_update") {
      const step = record(event.step_update) as unknown as AgyStep
      if (typeof step.step_index !== "number") return
      for (const mapped of mapper.step(step)) void send(mapped.kind, mapped.payload)
    } else if (event.event === "result") {
      finished(record(event.result) as unknown as AgyResult)
    }
  }

  const exited = (owner: AgyProcess, error: Error) => {
    if (process_ !== owner) return
    process_ = undefined
    // A cancelled turn's SIGINT takes agy down with it: that's the cancel.
    endTurn(
      turn?.cancelled === true ? { cancelled: true } : { detail: failureDetail(error.message) }
    )
  }

  /// Starts agy on the chat's conversation and waits for it to open one.
  const launch = async (): Promise<void> => {
    const variant = resolveSelection(options.models, selection)?.variant
    const spawned = await options.connector({
      command: options.command,
      args: [
        ...HEADLESS_ARGS,
        "--add-dir",
        options.cwd,
        ...(variant === undefined ? [] : ["--model", variant.slug]),
        ...(key === "" ? [] : ["--conversation", key]),
        ...(options.extraArgs ?? [])
      ],
      cwd: options.cwd,
      env: options.env
    })
    let timer: ReturnType<typeof setTimeout> | undefined
    try {
      key = await new Promise<string>((resolve, reject) => {
        timer = setTimeout(
          () => reject(new AgyStartError("Antigravity didn't start in time.")),
          startDeadlineMs
        )
        spawned.onEvent((event) => {
          if (event.event === "init") {
            resolve(text(event.conversation_id) ?? key)
          } else if (event.event === "result") {
            // Signed out, agy answers with a failed result and no `init`.
            reject(new AgyStartError(failureDetail(text(record(event.result).error))))
          }
        })
        spawned.onExit((error) => reject(new AgyStartError(failureDetail(error.message))))
      })
    } catch (cause) {
      spawned.close()
      throw cause
    } finally {
      clearTimeout(timer)
    }
    spawned.onEvent(handle)
    spawned.onExit((error) => exited(spawned, error))
    process_ = spawned
    stale = false
  }

  const relaunch = async () => {
    process_?.close()
    process_ = undefined
    await launch()
  }

  await launch()

  const run = async (input: string | PromptInput): Promise<{ stopReason: string }> => {
    const id = randomUUID()
    const done = new Promise<{ stopReason: string }>((resolve) => {
      turn = { id, cancelled: false, resolve }
    })
    void send("session.updated", { initiatedBy: "user", turnId: id, turnState: "started" })
    try {
      if (process_ === undefined || stale) await relaunch()
    } catch (cause) {
      endTurn({ detail: (cause as Error).message })
      return done
    }
    // Attachments are already files on disk; agy reads images with its own
    // file tool, and its stream input takes text only.
    const prompt = normalizePromptInput(input)
    process_!.send({
      event: "user",
      message: { content: withAttachmentNotes(prompt.text, prompt.attachments ?? []) }
    })
    return done
  }

  return {
    get key() {
      return key
    },
    configOptions: options_,
    // agy takes one turn at a time: a prompt sent mid-turn waits its turn.
    // A turn never rejects (a failure ends it with a reason), so the queue
    // keeps moving.
    prompt: (input) => {
      const next = queue.then(() => run(input))
      queue = next
      return next
    },
    cancel: async () => {
      const current = turn
      if (current === undefined) return
      current.cancelled = true
      process_?.interrupt()
      clearTimeout(cancelTimer)
      // agy that ignores the interrupt is stopped outright. The turn ending
      // first clears this.
      cancelTimer = setTimeout(() => {
        process_?.close()
        process_ = undefined
        endTurn({ cancelled: true })
      }, cancelGraceMs)
    },
    setConfigOption: async (configId, value) => {
      if (configId === MODEL_OPTION_ID) {
        const model = options.models.find((entry) => entry.id === value)
        if (model === undefined) throw new Error(`Unknown model: ${value}`)
        if (model.id !== selection.modelId) {
          selection.modelId = model.id
          // The new model keeps the tier when it has one by that name.
          selection.tier = resolveSelection(options.models, selection)!.variant.tier
          stale = true
        }
      } else if (configId === EFFORT_OPTION_ID) {
        const model = resolveSelection(options.models, selection)?.model
        if (model?.variants.some((variant) => variant.tier === value) !== true)
          throw new Error(`Unknown reasoning level: ${value}`)
        if (value !== selection.tier) {
          selection.tier = value
          stale = true
        }
      } else {
        throw new Error(`Antigravity has no setting named ${configId}`)
      }
      return options_()
    },
    close: () => {
      endTurn({ cancelled: true })
      process_?.close()
      process_ = undefined
    }
  }
}
