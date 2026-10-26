import { randomUUID } from "node:crypto"

import { turnLifecycleEvent, type AcpPromptResult } from "@codevisor/adapter-acp"
import {
  adapterPromise,
  normalizePromptInput,
  type AgentSessionHandle,
  type AgentSessionMetadata,
  type HarnessAccountContext,
  type PromptInput,
  type RuntimeEmit,
  type RuntimeEvent
} from "@codevisor/agent-runtime"
import { Effect } from "effect"

import {
  configOptions,
  currentModel,
  findModel,
  permissionsGated,
  resolveChange,
  type Catalog,
  type ModelRef,
  type Selection,
  decodeModelRef,
  sessionModes
} from "./catalog.js"
import { withCompletedDiffs, type ReadText } from "./file-diffs.js"
import { record, type JsonRecord } from "./internal.js"
import {
  makePermissionQuestions,
  permissionQuestion,
  type PermissionDecision
} from "./server-permissions.js"
import { prepareSubmission, promptBody, type Readable } from "./server-prompt.js"
import type { OpenCodeServer } from "./server.js"
import { skillReadUpdate, withSkillRead } from "./skill-tool.js"
import { OpenCodeSubagents } from "./subagents.js"
import {
  abandonTools,
  decodeEvent,
  foldEvent,
  initialFoldState,
  stopReason,
  totalTokens,
  turnFailure,
  withTurn,
  type ChildSession,
  type FoldOutput,
  type Terminal,
  type TrackedTool,
  type TurnState
} from "./translate.js"
import { failedTurnResult } from "./turn-failures.js"

export interface OpenCodeSessionInfo {
  readonly id: string
  readonly model?: ModelRef
  readonly agent?: string
}

export interface ServerSessionOptions {
  readonly server: OpenCodeServer
  readonly info: OpenCodeSessionInfo
  readonly cwd: string
  readonly events: AsyncIterator<unknown>
  readonly abort: () => void
  readonly catalog: Catalog
  readonly reloadCatalog: () => Promise<Catalog>
  readonly emit: RuntimeEmit
  readonly harnessName: string
  readonly account?: HarnessAccountContext
  readonly release: () => void
  readonly newMessageID: () => string
  readonly readable: Readable
  readonly readText?: ReadText
}

interface ActiveTurn {
  cancelled: boolean
  awaitingWake: boolean
  readonly done: (outcome: { readonly terminal: Terminal; readonly turn: TurnState }) => void
  readonly fail: (cause: Error) => void
}

export const openServerSession = (
  options: ServerSessionOptions
): { readonly metadata: AgentSessionMetadata; readonly handle: AgentSessionHandle } => {
  const { server, info, cwd } = options
  const path = `/api/session/${encodeURIComponent(info.id)}`
  const subagents = new OpenCodeSubagents()
  let fold = initialFoldState(info.id, cwd)
  let catalog = options.catalog
  let selection: Selection = {
    ...(info.model === undefined ? {} : { model: info.model }),
    ...(info.agent === undefined ? {} : { agent: info.agent })
  }
  let active: ActiveTurn | undefined
  let failure: Error | undefined
  let closed = false
  const steers = new Map<string, JsonRecord>()

  const emit = (event: RuntimeEvent): void => {
    void options.emit(event).catch(() => undefined)
  }
  const questions = makePermissionQuestions(emit, info.id)
  const emitUpdate = (update: JsonRecord): void => {
    for (const event of subagents.mapNotification({
      sessionId: info.id,
      update: skillReadUpdate(update)
    }))
      emit(event)
  }
  const emitChild = (params: JsonRecord): void => {
    for (const event of subagents.childUpdate(withSkillRead(params))) emit(event)
  }

  const finish = (terminal: Terminal): void => {
    const current = active
    const turn = fold.turn
    if (current === undefined || turn === undefined) return
    if (terminal === "interrupted") {
      const abandoned = abandonTools(fold)
      fold = abandoned.state
      for (const output of abandoned.outputs)
        if (output._tag === "update") emitUpdate(output.update)
    }
    fold = { ...fold, turn: undefined }
    steers.clear()
    active = undefined
    current.done({ terminal, turn })
  }

  const dropPending = (id: string): void => {
    steers.delete(id)
    const turn = fold.turn
    if (turn === undefined || !turn.pending.has(id)) return
    const pending = new Set(turn.pending)
    pending.delete(id)
    fold = withTurn(fold, { pending })
    if (active?.awaitingWake === true && pending.size === 0) finish("succeeded")
  }

  const wake = async (current: ActiveTurn, waiting: ReadonlyArray<string>): Promise<void> => {
    current.awaitingWake = true
    for (const id of waiting) {
      if (active !== current || current.cancelled) return
      await server
        .request(`${path}/prompt`, { body: { ...steers.get(id), id, delivery: "steer" } })
        .catch(() => dropPending(id))
    }
  }

  const onTerminal = async (terminal: Terminal): Promise<void> => {
    const current = active
    const turn = fold.turn
    if (current === undefined || turn === undefined) return
    const waiting = [...turn.pending]
    if (terminal === "succeeded" && waiting.length > 0 && !current.cancelled) {
      await wake(current, waiting)
      if (active !== current || (fold.turn?.pending.size ?? 0) > 0) return
    }
    finish(terminal)
  }

  const respondToPermission = async (
    request: JsonRecord,
    tool: TrackedTool | undefined,
    child: ChildSession | undefined
  ): Promise<void> => {
    const requestID = String(request.id)
    let decision: PermissionDecision | undefined = "once"
    if (permissionsGated(catalog, selection)) {
      decision = await questions.ask(permissionQuestion(request, tool, child), requestID)
    }
    if (decision === undefined) return
    const owner = encodeURIComponent(String(request.sessionID))
    await server
      .request(`/api/session/${owner}/permission/${encodeURIComponent(requestID)}/reply`, {
        body: { decision }
      })
      .catch(() => undefined)
  }

  const diffs = async (update: unknown, metadata: JsonRecord | undefined) => {
    if (metadata === undefined) return record(update) ?? {}
    return withCompletedDiffs(record(update) ?? {}, metadata, cwd, options.readText)
  }

  const handleOutput = async (output: FoldOutput): Promise<void> => {
    switch (output._tag) {
      case "update":
        emitUpdate(await diffs(output.update, output.metadata))
        return
      case "child":
        if (output.metadata === undefined) {
          emitChild(output.params)
        } else {
          emitChild({
            ...output.params,
            update: await diffs(output.params.update, output.metadata)
          })
        }
        return
      case "permission":
        void respondToPermission(output.request, output.tool, output.child)
        return
      case "permissionSettled":
        questions.settled(output.id)
        return
      case "form": {
        const owner = encodeURIComponent(String(output.form.sessionID))
        await server
          .request(`/api/session/${owner}/form/${encodeURIComponent(String(output.form.id))}`, {
            method: "DELETE"
          })
          .catch(() => undefined)
        return
      }
      case "terminal":
        await onTerminal(output.terminal)
    }
  }

  const selectionChanged = (type: string, data: JsonRecord): void => {
    const before = JSON.stringify(configOptions(catalog, selection))
    const mode = selection.agent ?? catalog.defaultModeID
    const model = decodeModelRef(data.model)
    if (type === "session.model.selected" && model !== undefined)
      selection = { ...selection, model }
    if (type === "session.agent.selected" && typeof data.agent === "string")
      selection = { ...selection, agent: data.agent }
    const next = configOptions(catalog, selection)
    if (JSON.stringify(next) !== before)
      emitUpdate({
        sessionUpdate: "config_option_update",
        configOptions: next.map((option) => ({ ...option, type: "select" }))
      })
    const currentModeId = selection.agent ?? catalog.defaultModeID
    if (currentModeId !== mode) emitUpdate({ sessionUpdate: "current_mode_update", currentModeId })
  }

  const handleEvent = async (value: unknown): Promise<void> => {
    const event = decodeEvent(value)
    if (event === undefined) return
    if (event.data.sessionID === info.id && event.type.endsWith(".selected"))
      selectionChanged(event.type, event.data)
    const folded = foldEvent(fold, event)
    fold = folded.state
    for (const output of folded.outputs) await handleOutput(output)
  }

  const pump = (async () => {
    try {
      for (let next = await options.events.next(); next.done !== true;) {
        await handleEvent(next.value).catch(() => undefined)
        next = await options.events.next()
      }
      throw new Error("OpenCode's event stream ended")
    } catch (cause) {
      if (closed) return
      failure = cause instanceof Error ? cause : new Error(String(cause))
      questions.cancelAll()
      const current = active
      active = undefined
      fold = { ...fold, turn: undefined }
      current?.fail(failure)
    }
  })()

  const sendUsage = async (turn: TurnState): Promise<void> => {
    const used = turn.usage === undefined ? 0 : totalTokens(turn.usage.last)
    const size = findModel(catalog.models, currentModel(catalog, selection))?.context
    if (used === 0 || size === undefined) return
    const session = record(record(await server.request(path).catch(() => undefined))?.data)
    emitUpdate({
      sessionUpdate: "usage_update",
      used,
      size,
      ...(typeof session?.cost === "number"
        ? { cost: { amount: session.cost, currency: "USD" } }
        : {})
    })
  }

  const submit = async (input: PromptInput, id: string): Promise<void> => {
    const submission = await prepareSubmission(input, catalog, options.readable)
    if (submission.kind === "command") {
      fold = withTurn(fold, { started: true, pending: new Set() })
      await server.request(`${path}/command`, { body: { ...submission.body, delivery: "steer" } })
    } else if (submission.kind === "compact") {
      await server.request(`${path}/compact`, { body: { id, delivery: "steer" } })
    } else {
      await server.request(`${path}/prompt`, {
        body: { ...submission.body, id, delivery: "steer" }
      })
    }
  }

  const runTurn = async (input: PromptInput): Promise<AcpPromptResult> => {
    if (failure !== undefined) throw failure
    if (closed) throw new Error("This OpenCode session is closed.")
    if (active !== undefined) throw new Error("OpenCode is already running a turn in this session.")
    const id = options.newMessageID()
    const outcome = new Promise<{ readonly terminal: Terminal; readonly turn: TurnState }>(
      (done, fail) => {
        active = { cancelled: false, awaitingWake: false, done, fail }
      }
    )
    const current = active!
    fold = { ...fold, turn: { inputID: id, started: false, pending: new Set([id]) } }
    try {
      await submit(input, id)
    } catch (cause) {
      if (active === current) {
        active = undefined
        fold = { ...fold, turn: undefined }
      }
      throw cause
    }
    const { terminal, turn } = await outcome
    const error = terminal === "interrupted" ? undefined : turnFailure(turn)
    if (error !== undefined) return failedTurnResult(error)
    await sendUsage(turn)
    return { stopReason: current.cancelled ? "cancelled" : stopReason(turn, terminal) }
  }

  const steer = async (input: PromptInput): Promise<boolean> => {
    const current = active
    if (current === undefined || current.cancelled || failure !== undefined || closed) return false
    const id = options.newMessageID()
    const body = await promptBody(input, options.readable)
    if (active !== current || current.cancelled || fold.turn === undefined) return false
    steers.set(id, body)
    fold = withTurn(fold, { pending: new Set([...fold.turn.pending, id]) })
    try {
      await server.request(`${path}/prompt`, {
        body: { ...body, id, delivery: "steer", resume: false }
      })
    } catch {
      dropPending(id)
      return false
    }
    return active === current && !current.cancelled
  }

  const cancelTurn = async (): Promise<void> => {
    questions.cancelAll()
    const current = active
    const interrupt = () =>
      server.request(`${path}/interrupt`, { method: "POST" }).catch(() => undefined)
    if (current === undefined) {
      await interrupt()
      return
    }
    current.cancelled = true
    const turn = fold.turn
    for (const id of turn?.pending ?? []) {
      if (id === turn?.inputID) continue
      await server
        .request(`${path}/inbox/${encodeURIComponent(id)}`, { method: "DELETE" })
        .catch(() => undefined)
      dropPending(id)
    }
    if (current.awaitingWake) {
      if (active === current) finish("interrupted")
      return
    }
    const interrupted = record(await interrupt())?.interrupted === true
    if (interrupted || active !== current || fold.turn?.started === true) return
    await server
      .request(`${path}/inbox/${encodeURIComponent(turn!.inputID)}`, { method: "DELETE" })
      .catch(() => undefined)
    if (active === current) finish("interrupted")
  }

  const select = async (configId: string, value: string) => {
    let change
    try {
      change = resolveChange(catalog, selection, configId, value)
    } catch {
      catalog = await options.reloadCatalog()
      change = resolveChange(catalog, selection, configId, value)
    }
    selection = { ...selection, ...change }
    if ("model" in change) await server.request(`${path}/model`, { body: { model: change.model } })
    else await server.request(`${path}/agent`, { body: { agent: change.agent } })
    return configOptions(catalog, selection)
  }

  const signInDetail = (result: AcpPromptResult): AcpPromptResult =>
    result.stopKind === "authRequired" && result.stopDetail === undefined
      ? { ...result, stopDetail: `${options.harnessName} isn't signed in. Sign in to continue.` }
      : result

  const handle: AgentSessionHandle = {
    prompt: (input) =>
      Effect.gen(function* () {
        const beforeTurn = options.account?.beforeTurn
        if (beforeTurn !== undefined)
          yield* Effect.promise(() => beforeTurn().catch(() => undefined))
        const turnId = randomUUID()
        yield* adapterPromise("promptTurnStart", () =>
          options.emit(turnLifecycleEvent(info.id, turnId, "started"))
        )
        const result = yield* adapterPromise("prompt", () => runTurn(normalizePromptInput(input)))
        yield* adapterPromise("promptTurnEnd", () =>
          options.emit(turnLifecycleEvent(info.id, turnId, "ended", signInDetail(result)))
        )
        return result
      }),
    steer: (input) => adapterPromise("steer", () => steer(normalizePromptInput(input))),
    cancel: Effect.gen(function* () {
      yield* adapterPromise("cancel", cancelTurn)
      yield* adapterPromise("cancelTurnEnd", () =>
        options.emit(
          turnLifecycleEvent(info.id, randomUUID(), "ended", { stopReason: "cancelled" })
        )
      )
      return { runtimeState: "reusable" as const }
    }),
    setMode: (modeId) =>
      Effect.gen(function* () {
        yield* adapterPromise("setMode", () => select("mode", modeId))
        yield* adapterPromise("setModeEvent", () =>
          options.emit({ kind: "session.updated", subjectId: info.id, payload: { modeId } })
        )
      }),
    setConfigOption: (configId, value) =>
      Effect.gen(function* () {
        const updated = yield* adapterPromise("setConfigOption", () => select(configId, value))
        yield* adapterPromise("setConfigOptionEvent", () =>
          options.emit({
            kind: "session.updated",
            subjectId: info.id,
            payload: {
              configId,
              configOptions: updated,
              value,
              ...(configId === "mode" ? { modeId: value } : {})
            }
          })
        )
        return updated
      }),
    answerQuestion: (questionId, answer) =>
      adapterPromise("answerQuestion", async () => questions.answer(questionId, answer)),
    close: adapterPromise("close", async () => {
      if (closed) return
      closed = true
      questions.cancelAll()
      const current = active
      if (current !== undefined) {
        active = undefined
        fold = { ...fold, turn: undefined }
        await server.request(`${path}/interrupt`, { method: "POST" }).catch(() => undefined)
        current.fail(new Error("This OpenCode session was closed."))
      }
      options.abort()
      await pump
      options.release()
    })
  }

  return {
    metadata: {
      sessionId: info.id,
      configOptions: configOptions(catalog, selection),
      modes: sessionModes(catalog, selection),
      skills: catalog.skills
    },
    handle
  }
}
