import type { DiffStat, SessionConfigOption, SessionModeState } from "@herdman/api"
import { randomUUID } from "node:crypto"
import { Effect } from "effect"
import { diffStatsFromUnified, lineCount } from "../../diff-stats.js"
import {
  adapterPromise,
  type AgentProvider,
  type AgentRuntimeError,
  type AgentSessionHandle,
  type CreatedAgentSession,
  type HarnessDefinition,
  type LoadedAgentSession,
  type ProviderEnvironment,
  type RuntimeEmit,
  type RuntimeEvent
} from "../../types.js"
import { spawnCodexClient, type CodexClient, type CodexConnector } from "./client.js"

export interface CodexProviderConfig {
  /// Injectable for tests: scripted app-server sessions instead of a spawned
  /// codex binary.
  readonly connector?: CodexConnector
}

interface CodexModel {
  readonly value: string
  readonly name: string
  readonly efforts: ReadonlyArray<string>
  readonly defaultEffort: string
}

/// Approval/sandbox presets, mirroring the modes the codex-acp adapter (and
/// the Codex IDE extensions) expose. Applied as sticky turn/start overrides.
interface CodexMode {
  readonly id: string
  readonly name: string
  readonly description: string
  readonly approvalPolicy: string
  readonly sandboxPolicy: Record<string, unknown>
}

const CODEX_MODES: ReadonlyArray<CodexMode> = [
  {
    approvalPolicy: "on-request",
    description: "Requires approval to edit files and run commands.",
    id: "read-only",
    name: "Read-only",
    sandboxPolicy: { networkAccess: false, type: "readOnly" }
  },
  {
    approvalPolicy: "on-request",
    description: "Read and edit files, and run commands.",
    id: "agent",
    name: "Agent",
    sandboxPolicy: {
      excludeSlashTmp: false,
      excludeTmpdirEnvVar: false,
      networkAccess: false,
      type: "workspaceWrite",
      writableRoots: []
    }
  },
  {
    approvalPolicy: "never",
    description:
      "Codex can edit files outside this workspace and run commands with network access.",
    id: "agent-full-access",
    name: "Agent (full access)",
    sandboxPolicy: { type: "dangerFullAccess" }
  }
]

const DEFAULT_CODEX_MODE = "agent"

interface CodexSession {
  readonly key: string
  readonly threadId: string
  readonly client: CodexClient
  readonly emit: RuntimeEmit
  readonly cwd: string
  activeTurnId: string | undefined
  pendingPrompt: { resolve: (value: { stopReason: string }) => void } | undefined
  interruptRequested: boolean
  currentModel: string
  currentEffort: string | undefined
  currentModeId: string
  models: ReadonlyArray<CodexModel>
  /// item id → tool-call kind, so completions map back without re-parsing.
  readonly itemKinds: Map<string, string>
}

export const makeCodexProvider = (
  environment: ProviderEnvironment,
  config: CodexProviderConfig = {}
): AgentProvider => {
  const connector = config.connector ?? spawnCodexClient

  const locateCodex = (definition: HarnessDefinition): string => {
    const binary = definition.detectBinaries[0] ?? "codex"
    const located = environment.locateExecutable(binary, environment.env)
    if (located === undefined) {
      throw new Error(`${binary} not found on PATH`)
    }
    return located
  }

  const connect = async (definition: HarnessDefinition, cwd: string): Promise<CodexClient> => {
    const command = locateCodex(definition)
    const client = await connector({ command, cwd, env: environment.env })
    await client.request("initialize", {
      clientInfo: { name: "HerdMan", title: "HerdMan", version: "0.1.0" }
    })
    // The server rejects all other requests until this lands.
    client.notify("initialized")
    return client
  }

  const startSession = async (
    definition: HarnessDefinition,
    cwd: string,
    emit: RuntimeEmit,
    resumeThreadId: string | undefined
  ): Promise<CodexSession> => {
    const client = await connect(definition, cwd)
    let response: { thread?: { id?: string }; model?: string }
    if (resumeThreadId === undefined) {
      response = await client.request("thread/start", { cwd })
    } else {
      try {
        response = await client.request("thread/resume", { cwd, threadId: resumeThreadId })
      } catch {
        // Sessions created by the old codex-acp adapter may not be app-server
        // thread ids; fall back to a fresh thread rather than failing the
        // session outright (history is lost, the session keeps working).
        response = await client.request("thread/start", { cwd })
      }
    }
    const threadId = response.thread?.id
    if (threadId === undefined) {
      client.close()
      throw new Error("codex app-server did not return a thread id")
    }
    const session: CodexSession = {
      activeTurnId: undefined,
      client,
      currentEffort: undefined,
      currentModeId: DEFAULT_CODEX_MODE,
      currentModel: response.model ?? "",
      cwd,
      emit,
      interruptRequested: false,
      itemKinds: new Map(),
      key: resumeThreadId ?? threadId,
      models: [],
      pendingPrompt: undefined,
      threadId
    }
    try {
      const modelList = await client.request<{ data?: Array<Record<string, unknown>> }>(
        "model/list",
        {}
      )
      session.models = (modelList.data ?? []).flatMap((model) => {
        if (model.hidden === true) return []
        const value = typeof model.model === "string" ? model.model : undefined
        if (value === undefined) return []
        const efforts = Array.isArray(model.supportedReasoningEfforts)
          ? model.supportedReasoningEfforts.flatMap((option) =>
              typeof option === "object" &&
              option !== null &&
              typeof (option as Record<string, unknown>).reasoningEffort === "string"
                ? [(option as Record<string, unknown>).reasoningEffort as string]
                : []
            )
          : []
        return [
          {
            defaultEffort:
              typeof model.defaultReasoningEffort === "string"
                ? model.defaultReasoningEffort
                : "medium",
            efforts,
            name: typeof model.displayName === "string" ? model.displayName : value,
            value
          }
        ]
      })
      const current = session.models.find((model) => model.value === session.currentModel)
      if (current !== undefined) {
        session.currentEffort = current.defaultEffort
      }
    } catch {
      session.models = []
    }
    client.onNotification((method, params) => {
      handleNotification(session, method, params)
    })
    client.onRequest(async (method, _params) => approvalResponse(method))
    client.onClose((error) => {
      session.pendingPrompt?.resolve({ stopReason: "cancelled" })
      session.pendingPrompt = undefined
      void session.emit({
        kind: "session.error",
        payload: { message: error.message },
        subjectId: session.key
      })
    })
    return session
  }

  const configOptionsFor = (session: CodexSession): ReadonlyArray<SessionConfigOption> => {
    const options: Array<SessionConfigOption> = []
    if (session.models.length > 0) {
      options.push({
        category: "model",
        currentValue: session.currentModel,
        id: "model",
        name: "Model",
        options: session.models.map((model) => ({ name: model.name, value: model.value }))
      })
    } else if (session.currentModel.length > 0) {
      options.push({
        category: "model",
        currentValue: session.currentModel,
        id: "model",
        name: "Model",
        options: [{ name: session.currentModel, value: session.currentModel }]
      })
    }
    const current = session.models.find((model) => model.value === session.currentModel)
    const efforts = current?.efforts ?? []
    if (efforts.length > 0) {
      options.push({
        category: "thought_level",
        currentValue:
          session.currentEffort !== undefined && efforts.includes(session.currentEffort)
            ? session.currentEffort
            : (current?.defaultEffort ?? efforts[0] ?? "medium"),
        id: "effort",
        name: "Reasoning",
        options: efforts.map((effort) => ({
          name: effort === "xhigh" ? "X-High" : effort[0]?.toUpperCase() + effort.slice(1),
          value: effort
        }))
      })
    }
    return options
  }

  const modesFor = (session: CodexSession): SessionModeState => ({
    availableModes: CODEX_MODES.map((mode) => ({
      description: mode.description,
      id: mode.id,
      name: mode.name
    })),
    currentModeId: session.currentModeId
  })

  const handleFor = (session: CodexSession): AgentSessionHandle => ({
    cancel: adapterPromise("cancel", async () => {
      const turnId = session.activeTurnId
      if (turnId === undefined) return
      session.interruptRequested = true
      try {
        await session.client.request("turn/interrupt", {
          threadId: session.threadId,
          turnId
        })
      } catch {
        // The turn may already be over.
      }
    }),
    close: adapterPromise("close", async () => {
      session.client.close()
    }),
    prompt: (text) =>
      adapterPromise("prompt", async () => {
        const pending = new Promise<{ stopReason: string }>((resolve) => {
          session.pendingPrompt = { resolve }
        })
        const mode = CODEX_MODES.find((candidate) => candidate.id === session.currentModeId)
        await session.client.request("turn/start", {
          input: [{ text, type: "text" }],
          threadId: session.threadId,
          ...(session.currentModel.length === 0 ? {} : { model: session.currentModel }),
          ...(session.currentEffort === undefined ? {} : { effort: session.currentEffort }),
          ...(mode === undefined
            ? {}
            : { approvalPolicy: mode.approvalPolicy, sandboxPolicy: mode.sandboxPolicy })
        })
        return pending
      }),
    setConfigOption: (configId, value) =>
      adapterPromise("setConfigOption", async () => {
        // Applied as sticky turn/start overrides on subsequent turns.
        if (configId === "model") {
          session.currentModel = value
          const model = session.models.find((candidate) => candidate.value === value)
          if (
            model !== undefined &&
            (session.currentEffort === undefined || !model.efforts.includes(session.currentEffort))
          ) {
            session.currentEffort = model.defaultEffort
          }
        } else if (configId === "effort") {
          session.currentEffort = value
        } else {
          throw new Error(`Unknown config option: ${configId}`)
        }
        await session.emit({
          kind: "session.updated",
          payload: { configId, configOptions: configOptionsFor(session), value },
          subjectId: session.key
        })
      }),
    setMode: (modeId) =>
      adapterPromise("setMode", async () => {
        if (!CODEX_MODES.some((mode) => mode.id === modeId)) {
          throw new Error(`Unknown Codex mode: ${modeId}`)
        }
        session.currentModeId = modeId
        await session.emit({
          kind: "session.updated",
          payload: { modeId },
          subjectId: session.key
        })
      })
  })

  return {
    createSession: (definition, cwd, emit): Effect.Effect<CreatedAgentSession, AgentRuntimeError> =>
      adapterPromise("createSession", async () => {
        const session = await startSession(definition, cwd, emit, undefined)
        return {
          handle: handleFor(session),
          metadata: {
            configOptions: configOptionsFor(session),
            modes: modesFor(session),
            sessionId: session.key
          }
        }
      }),
    id: "codex",
    loadSession: (
      definition,
      agentSessionId,
      cwd,
      emit
    ): Effect.Effect<LoadedAgentSession, AgentRuntimeError> =>
      adapterPromise("loadSession", async () => {
        const session = await startSession(definition, cwd, emit, agentSessionId)
        return { handle: handleFor(session), sessionId: session.key }
      }),
    readiness: (definition) => {
      const installed = definition.detectBinaries.some((binary) =>
        environment.executableExists(binary, environment.env)
      )
      return installed
        ? { state: "ready" }
        : { detail: "CLI not found on PATH", state: "unavailable" }
    }
  }
}

/// Approvals are auto-accepted, matching the Claude provider's auto-allow
/// posture; this handler is the seam for a real permission UI.
const approvalResponse = (method: string): Promise<unknown> => {
  switch (method) {
    case "item/commandExecution/requestApproval":
    case "item/fileChange/requestApproval":
    case "item/permissions/requestApproval":
      return Promise.resolve({ decision: "accept" })
    default:
      return Promise.reject(new Error(`Unsupported approval request: ${method}`))
  }
}

// MARK: notification mapping

const handleNotification = (session: CodexSession, method: string, params: unknown): void => {
  const payload = isRecord(params) ? params : {}
  switch (method) {
    case "turn/started": {
      const turn = isRecord(payload.turn) ? payload.turn : {}
      session.activeTurnId = typeof turn.id === "string" ? turn.id : randomUUID()
      void session.emit({
        kind: "session.updated",
        payload: {
          initiatedBy: session.pendingPrompt === undefined ? "agent" : "user",
          turnId: session.activeTurnId,
          turnState: "started"
        },
        subjectId: session.key
      })
      break
    }
    case "turn/completed": {
      const turn = isRecord(payload.turn) ? payload.turn : {}
      const status = typeof turn.status === "string" ? turn.status : "completed"
      const stopReason =
        status === "interrupted" || session.interruptRequested
          ? "cancelled"
          : status === "failed"
            ? "end_turn"
            : "end_turn"
      if (status === "failed" && !session.interruptRequested) {
        const error = isRecord(turn.error) ? turn.error : {}
        void session.emit({
          kind: "session.error",
          payload: {
            message: typeof error.message === "string" ? error.message : "Codex turn failed"
          },
          subjectId: session.key
        })
      }
      const pending = session.pendingPrompt
      session.pendingPrompt = undefined
      session.interruptRequested = false
      const turnId = session.activeTurnId ?? randomUUID()
      session.activeTurnId = undefined
      void session
        .emit({
          kind: "session.updated",
          payload: {
            initiatedBy: pending === undefined ? "agent" : "user",
            stopReason,
            turnId,
            turnState: "ended"
          },
          subjectId: session.key
        })
        .then(() => pending?.resolve({ stopReason }))
      break
    }
    case "item/agentMessage/delta": {
      void session.emit({
        kind: "session.output",
        payload: {
          content: { text: String(payload.delta ?? ""), type: "text" },
          sessionUpdate: "agent_message_chunk",
          ...(typeof payload.itemId === "string" ? { messageId: payload.itemId } : {})
        },
        subjectId: session.key
      })
      break
    }
    case "item/reasoning/textDelta":
    case "item/reasoning/summaryTextDelta": {
      void session.emit({
        kind: "session.output",
        payload: {
          content: { text: String(payload.delta ?? ""), type: "text" },
          sessionUpdate: "agent_thought_chunk"
        },
        subjectId: session.key
      })
      break
    }
    case "item/started":
    case "item/completed": {
      const item = isRecord(payload.item) ? payload.item : {}
      // Codex (as of 0.142) emits no reasoning text deltas — the reasoning
      // item's lifecycle is the only thinking signal, so an empty thought
      // chunk drives the client's ephemeral "Thinking…" state through the
      // otherwise silent gap.
      if (item.type === "reasoning" && method === "item/started") {
        void session.emit({
          kind: "session.output",
          payload: {
            content: { text: "", type: "text" },
            sessionUpdate: "agent_thought_chunk"
          },
          subjectId: session.key
        })
        break
      }
      emitItemLifecycle(session, item, method === "item/started")
      break
    }
    case "item/fileChange/patchUpdated": {
      // Codex streams the patch as the model generates it (gated behind the
      // apply_patch_streaming_events feature we enable at spawn) — this is
      // the realtime counter signal. These arrive BEFORE item/started for
      // the same item, so the first one opens the tool call.
      const itemId = typeof payload.itemId === "string" ? payload.itemId : undefined
      if (itemId === undefined) break
      const stats = fileChangeStats(payload.changes)
      if (!session.itemKinds.has(itemId)) {
        session.itemKinds.set(itemId, "edit")
        void session.emit({
          kind: "session.output",
          payload: {
            kind: "edit",
            sessionUpdate: "tool_call",
            status: "in_progress",
            title: fileChangeTitle(payload.changes, false),
            toolCallId: itemId,
            ...(stats.length === 0 ? {} : { diffStats: stats })
          },
          subjectId: session.key
        })
        break
      }
      if (stats.length === 0) break
      void session.emit({
        kind: "session.output",
        payload: {
          diffStats: stats,
          sessionUpdate: "tool_call_update",
          status: "in_progress",
          toolCallId: itemId
        },
        subjectId: session.key
      })
      break
    }
    case "turn/plan/updated": {
      const plan = Array.isArray(payload.plan) ? payload.plan : []
      void session.emit({
        kind: "session.output",
        payload: {
          entries: plan.flatMap((step) =>
            isRecord(step)
              ? [
                  {
                    content: String(step.step ?? ""),
                    priority: "medium",
                    status: planStatus(step.status)
                  }
                ]
              : []
          ),
          sessionUpdate: "plan"
        },
        subjectId: session.key
      })
      break
    }
    case "error": {
      if (payload.willRetry === true) break
      void session.emit({
        kind: "session.error",
        payload: { message: String(payload.message ?? "Codex error") },
        subjectId: session.key
      })
      break
    }
    default:
      // turn/diff/updated is deliberately ignored for stats: it aggregates the
      // whole turn, and HerdMan counters are per tool call.
      break
  }
}

const emitItemLifecycle = (
  session: CodexSession,
  item: Record<string, unknown>,
  started: boolean
): void => {
  const itemId = typeof item.id === "string" ? item.id : undefined
  if (itemId === undefined) return
  const type = typeof item.type === "string" ? item.type : ""
  const event = (payload: Record<string, unknown>): RuntimeEvent => ({
    kind: "session.output",
    payload,
    subjectId: session.key
  })

  switch (type) {
    case "commandExecution": {
      const command = typeof item.command === "string" ? item.command : ""
      if (started) {
        session.itemKinds.set(itemId, "execute")
        void session.emit(
          event({
            kind: "execute",
            sessionUpdate: "tool_call",
            status: "in_progress",
            title: command.length > 0 ? `Ran ${firstLine(command)}` : "Ran command",
            toolCallId: itemId
          })
        )
      } else {
        void session.emit(
          event({
            sessionUpdate: "tool_call_update",
            status: commandStatus(item),
            toolCallId: itemId,
            ...(typeof item.aggregatedOutput === "string"
              ? { rawOutput: item.aggregatedOutput }
              : {})
          })
        )
      }
      break
    }
    case "fileChange": {
      const stats = fileChangeStats(item.changes)
      const content = fileChangeDiffBlocks(item.changes)
      if (started) {
        // The streamed patchUpdated events may have opened this call already;
        // tool_call upserts merge in the client, so re-sending is safe and
        // carries the final title/diff content.
        session.itemKinds.set(itemId, "edit")
        void session.emit(
          event({
            kind: "edit",
            sessionUpdate: "tool_call",
            status: "in_progress",
            title: fileChangeTitle(item.changes, false),
            toolCallId: itemId,
            ...(stats.length === 0 ? {} : { diffStats: stats }),
            ...(content.length === 0 ? {} : { content })
          })
        )
      } else {
        void session.emit(
          event({
            sessionUpdate: "tool_call_update",
            status: patchStatus(item),
            title: fileChangeTitle(item.changes, true),
            toolCallId: itemId,
            ...(stats.length === 0 ? {} : { diffStats: stats }),
            ...(content.length === 0 ? {} : { content })
          })
        )
      }
      break
    }
    case "mcpToolCall": {
      const title = `${String(item.server ?? "")}.${String(item.tool ?? "")}`
      if (started) {
        session.itemKinds.set(itemId, "other")
        void session.emit(
          event({
            kind: "other",
            sessionUpdate: "tool_call",
            status: "in_progress",
            title,
            toolCallId: itemId
          })
        )
      } else {
        void session.emit(
          event({
            sessionUpdate: "tool_call_update",
            status: item.status === "failed" ? "failed" : "completed",
            toolCallId: itemId
          })
        )
      }
      break
    }
    case "webSearch": {
      if (started) {
        void session.emit(
          event({
            kind: "fetch",
            sessionUpdate: "tool_call",
            status: "in_progress",
            title: typeof item.query === "string" ? `Searched ${item.query}` : "Web search",
            toolCallId: itemId
          })
        )
      } else {
        void session.emit(
          event({ sessionUpdate: "tool_call_update", status: "completed", toolCallId: itemId })
        )
      }
      break
    }
    case "agentMessage":
      // Text already streamed via item/agentMessage/delta.
      break
    default:
      break
  }
}

// MARK: helpers

/// For adds/deletes codex sends the raw file content in `diff`, not a unified
/// diff — every line counts. Updates carry a real unified diff body.
const fileChangeStats = (changes: unknown): Array<DiffStat> => {
  if (!Array.isArray(changes)) return []
  return changes.flatMap((change) => {
    if (!isRecord(change)) return []
    const path = typeof change.path === "string" ? change.path : undefined
    const diff = typeof change.diff === "string" ? change.diff : undefined
    if (path === undefined || diff === undefined) return []
    switch (changeKind(change)) {
      case "add":
        return [{ added: lineCount(diff), path, removed: 0 }]
      case "delete":
        return [{ added: 0, path, removed: lineCount(diff) }]
      default:
        return [diffStatsFromUnified(path, diff)]
    }
  })
}

const changeKind = (change: Record<string, unknown>): string => {
  const kind = change.kind
  if (isRecord(kind) && typeof kind.type === "string") return kind.type
  return typeof kind === "string" ? kind : "update"
}

const fileChangeDiffBlocks = (
  changes: unknown
): Array<{ type: "diff"; path: string; oldText: string | null; newText: string }> => {
  if (!Array.isArray(changes)) return []
  return changes.flatMap((change) => {
    if (!isRecord(change)) return []
    const path = typeof change.path === "string" ? change.path : undefined
    const diff = typeof change.diff === "string" ? change.diff : undefined
    if (path === undefined || diff === undefined) return []
    switch (changeKind(change)) {
      case "add":
        return [{ newText: diff, oldText: null, path, type: "diff" as const }]
      case "delete":
        return [{ newText: "", oldText: diff, path, type: "diff" as const }]
      default: {
        const texts = textsFromUnified(diff)
        if (texts === undefined) return []
        return [{ newText: texts.newText, oldText: texts.oldText, path, type: "diff" as const }]
      }
    }
  })
}

/// Reconstructs old/new text from a unified diff body so the client's DiffView
/// can render it. Hunk headers reset nothing here — the reconstruction is a
/// display approximation covering the changed regions and their context.
const textsFromUnified = (
  diff: string
): { oldText: string | null; newText: string } | undefined => {
  const oldLines: Array<string> = []
  const newLines: Array<string> = []
  let sawContent = false
  for (const line of diff.split("\n")) {
    if (line.startsWith("+++") || line.startsWith("---") || line.startsWith("@@")) continue
    if (line.startsWith("+")) {
      newLines.push(line.slice(1))
      sawContent = true
    } else if (line.startsWith("-")) {
      oldLines.push(line.slice(1))
      sawContent = true
    } else {
      const text = line.startsWith(" ") ? line.slice(1) : line
      oldLines.push(text)
      newLines.push(text)
    }
  }
  if (!sawContent) return undefined
  return {
    newText: `${newLines.join("\n")}\n`,
    oldText: oldLines.length === 0 ? null : `${oldLines.join("\n")}\n`
  }
}

const fileChangeTitle = (changes: unknown, done: boolean): string => {
  const verb = done ? "Edited" : "Editing"
  if (Array.isArray(changes)) {
    const paths = changes.flatMap((change) =>
      isRecord(change) && typeof change.path === "string" ? [change.path] : []
    )
    const first = paths[0]?.split("/").at(-1)
    if (first !== undefined) {
      return paths.length > 1 ? `${verb} ${first} +${paths.length - 1} more` : `${verb} ${first}`
    }
  }
  return done ? "Edited files" : "Editing files"
}

const commandStatus = (item: Record<string, unknown>): string => {
  switch (item.status) {
    case "completed":
      return typeof item.exitCode === "number" && item.exitCode !== 0 ? "failed" : "completed"
    case "failed":
      return "failed"
    case "declined":
      return "cancelled"
    default:
      return "completed"
  }
}

const patchStatus = (item: Record<string, unknown>): string => {
  switch (item.status) {
    case "failed":
      return "failed"
    case "declined":
      return "cancelled"
    default:
      return "completed"
  }
}

const planStatus = (status: unknown): string => {
  switch (status) {
    case "inProgress":
    case "in_progress":
      return "in_progress"
    case "completed":
      return "completed"
    default:
      return "pending"
  }
}

const firstLine = (text: string): string => text.split("\n")[0]?.slice(0, 80) ?? ""

const isRecord = (value: unknown): value is Record<string, unknown> =>
  typeof value === "object" && value !== null
