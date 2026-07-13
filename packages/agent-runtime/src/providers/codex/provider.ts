import type {
  CanonicalModeId,
  DiffStat,
  GoalStatus,
  QuestionAnswerEntry,
  QuestionSpec,
  SessionConfigOption,
  SessionGoal,
  SessionModeState
} from "@herdman/api"
import { execFileSync } from "node:child_process"
import { randomUUID } from "node:crypto"
import { Effect } from "effect"
import { listCodexAgentSessions } from "../../agent-sessions.js"
import { withAttachmentNotes } from "../../attachments.js"
import {
  backgroundTerminalKey,
  DEFAULT_PROMOTION_DELAY_MS,
  type BackgroundTerminalIntegration,
  type ExternalTerminalStream
} from "../../background-terminals.js"
import { diffStatsFromUnified, lineCount } from "../../diff-stats.js"
import {
  adapterPromise,
  normalizePromptInput,
  type AgentProvider,
  type AgentRuntimeError,
  type AgentSessionHandle,
  type CreatedAgentSession,
  type HarnessDefinition,
  type HarnessAccountContext,
  type LoadedAgentSession,
  type PromptInput,
  type ProviderEnvironment,
  type QuestionAnswer,
  type RuntimeEmit,
  type RuntimeEvent,
  type SetGoalUpdate,
  type ToolGatewayConfig
} from "../../types.js"
import { findKnownModel, highestThinkingLevel, sanitizeModelValue } from "../model-selection.js"
import { spawnCodexClient, type CodexClient, type CodexConnector } from "./client.js"
import { killCodexCommandProcesses, type CodexCommandKiller } from "./process-kill.js"

type CodexInputItem =
  | { readonly text: string; readonly type: "text" }
  | { readonly path: string; readonly type: "localImage" }

/// Builds the turn/start input items: images go by materialized temp-file
/// path (the app-server's `localImage`), other files by path note in the text.
const codexInput = (input: PromptInput): Array<CodexInputItem> => {
  const attachments = input.attachments ?? []
  const images = attachments.filter((attachment) => attachment.kind === "image")
  const files = attachments.filter((attachment) => attachment.kind !== "image")
  const text = withAttachmentNotes(input.text, files)
  const items: Array<CodexInputItem> = []
  if (text !== "" || images.length === 0) {
    items.push({ text, type: "text" })
  }
  for (const image of images) {
    items.push({ path: image.path, type: "localImage" })
  }
  return items
}

export interface CodexProviderConfig {
  /// Injectable for tests: scripted app-server sessions instead of a spawned
  /// codex binary.
  readonly connector?: CodexConnector
  /// Injectable for tests: reads a resolved Codex binary's version.
  readonly versionReader?: (command: string, env: NodeJS.ProcessEnv) => string | undefined
  /// When set, command executions mirror their streamed output
  /// (`item/commandExecution/outputDelta`) into server-owned terminals;
  /// commands that outlive the promotion delay surface as terminal tabs.
  /// Codex owns the processes, so the mirrors are read-only for input; kill
  /// is best-effort via the codex process tree (see process-kill.ts).
  readonly backgroundTerminals?: BackgroundTerminalIntegration
  /// Injectable for tests: the best-effort process-tree kill.
  readonly killCommandProcesses?: CodexCommandKiller
}

interface CodexModel {
  readonly value: string
  readonly name: string
  readonly efforts: ReadonlyArray<string>
  readonly defaultEffort: string
  /// Whether the model's service tiers include the fast ("priority") tier.
  readonly supportsFast: boolean
  /// Whether the model's catalog default service tier is the fast tier.
  readonly defaultsToFast: boolean
}

/// The wire value Codex uses for its fast service tier (the UI calls it
/// "priority"); "default" is the explicit standard-routing sentinel.
const CODEX_FAST_TIER = "priority"
const CODEX_STANDARD_TIER = "default"

/// Approval/sandbox presets, mirroring the modes the codex-acp adapter (and
/// the Codex IDE extensions) expose. Applied as sticky turn/start overrides.
interface CodexMode {
  readonly id: string
  readonly name: string
  readonly description: string
  readonly canonicalId: CanonicalModeId
  readonly approvalPolicy: string
  readonly sandboxPolicy: Record<string, unknown>
  /// When set, turn/start also sends the EXPERIMENTAL collaborationMode
  /// preset (unlocked by `capabilities.experimentalApi` at initialize).
  readonly collaboration?: "plan"
}

const CODEX_MODES: ReadonlyArray<CodexMode> = [
  {
    approvalPolicy: "on-request",
    canonicalId: "plan",
    collaboration: "plan",
    description: "Plans first: proposes an implementation plan before coding.",
    id: "plan",
    name: "Plan",
    sandboxPolicy: { networkAccess: false, type: "readOnly" }
  },
  {
    approvalPolicy: "on-request",
    canonicalId: "readOnly",
    description: "Requires approval to edit files and run commands.",
    id: "read-only",
    name: "Read-only",
    sandboxPolicy: { networkAccess: false, type: "readOnly" }
  },
  {
    approvalPolicy: "on-request",
    canonicalId: "ask",
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
    canonicalId: "fullAccess",
    description:
      "Codex can edit files outside this workspace and run commands with network access.",
    id: "agent-full-access",
    name: "Agent (full access)",
    sandboxPolicy: { type: "dangerFullAccess" }
  }
]

const DEFAULT_CODEX_MODE = "agent-full-access"

/// Accounting-only goal snapshots (tokensUsed/timeUsedSeconds ticks) are
/// rate-limited: every emission is a permanent events-table row replayed on
/// session open, and codex flushes accounting several times per turn.
/// Status/objective/budget changes and out-of-band snapshots bypass this.
export const GOAL_ACCOUNTING_INTERVAL_MS = 2000

const GOAL_STATUSES: ReadonlySet<string> = new Set([
  "active",
  "paused",
  "blocked",
  "usageLimited",
  "budgetLimited",
  "complete"
])

/// One blocking server→client ask awaiting the human's answer — either the
/// model's `item/tool/requestUserInput` or an MCP server's
/// `mcpServer/elicitation/request`. `resolve`/`reject` settle the held
/// JSON-RPC handler promise; `respond` builds the source-specific reply from
/// the wire answers; `cancelResponse` is the source-specific dismissal reply
/// (undefined = reject the JSON-RPC request instead).
interface PendingCodexQuestion {
  readonly questions: ReadonlyArray<QuestionSpec>
  readonly resolve: (response: unknown) => void
  readonly reject: (error: Error) => void
  readonly timer: NodeJS.Timeout | undefined
  readonly respond: (answers: NonNullable<QuestionAnswer["answers"]>) => unknown
  readonly cancelResponse?: unknown
}

/// One in-flight command execution's terminal mirror. `promoted` flips when
/// the command outlives the promotion delay — that is when it appears in the
/// `backgroundTasks` snapshot (and therefore as a tab).
interface CodexCommandTerminal {
  readonly itemId: string
  readonly terminalKey: string
  readonly description: string
  readonly stream: ExternalTerminalStream
  promoted: boolean
  promotionTimer: NodeJS.Timeout | undefined
}

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
  /// Undefined until the user picks a speed — the model's default tier applies.
  currentSpeed: "standard" | "fast" | undefined
  currentModeId: string
  /// True once a Plan-mode turn has run. Codex's collaboration mode is sticky
  /// server-side, so after engaging Plan we keep sending an explicit
  /// collaboration mode every turn ("default" leaves Plan) instead of omitting
  /// it — otherwise the model stays in Plan mode after the toggle flips off.
  collaborationEngaged: boolean
  models: ReadonlyArray<CodexModel>
  /// item id → tool-call kind, so completions map back without re-parsing.
  readonly itemKinds: Map<string, string>
  /// agentMessage item id → wire phase ("commentary" | "final"), captured from
  /// `item/started` so every streamed delta carries the message's finality.
  /// Codex tags items with `phase: "commentary" | "final_answer"` when the
  /// model emits harmony channels; untagged items stay unknown and clients
  /// fall back to optimistic (last-text-wins) rendering.
  readonly messagePhases: Map<string, "commentary" | "final">
  /// Collab (sub)agent thread id → the spawnAgent tool call id that created
  /// it. Items arriving on those threads are tagged with that parent so
  /// clients can nest them; the main thread's id is `threadId`.
  readonly collabThreads: Map<string, string>
  /// item id → human-readable title, so approval prompts can say WHAT is
  /// being approved (approval params carry only the item id).
  readonly itemTitles: Map<string, string>
  /// Read-only terminal mirrors for in-flight command executions, keyed by
  /// item id. Codex owns the processes; we own the mirrors.
  readonly commandTerminals: Map<string, CodexCommandTerminal>
  readonly backgroundTerminals: BackgroundTerminalIntegration | undefined
  readonly killCommandProcesses: CodexCommandKiller
  /// Goal-snapshot throttle state: the last snapshot broadcast to the wire,
  /// when it went out, and the freshest one held back by the rate limit
  /// (flushed at turn end so final totals always persist).
  lastEmittedGoal: SessionGoal | undefined
  lastGoalEmitAtMs: number
  pendingGoalSnapshot: SessionGoal | undefined
  /// question id (= codex item id) → held requestUserInput handler.
  readonly pendingQuestions: Map<string, PendingCodexQuestion>
}

export const makeCodexProvider = (
  environment: ProviderEnvironment,
  config: CodexProviderConfig = {}
): AgentProvider => {
  const connector = config.connector ?? spawnCodexClient
  const versionReader = config.versionReader ?? readCodexVersion

  // PATH first, then fallbackPaths. When both the user CLI and Codex.app
  // bundle are present, compare resolved binary versions and run the newer
  // app-server so HerdMan sees the newest Codex model catalog.
  const codexCandidates = (definition: HarnessDefinition): ReadonlyArray<string> => [
    ...definition.detectBinaries,
    ...(definition.fallbackPaths ?? [])
  ]

  const locateCodex = (definition: HarnessDefinition): string => {
    const locatedCandidates: Array<{ command: string; version: string | undefined }> = []
    const seen = new Set<string>()
    for (const candidate of codexCandidates(definition)) {
      const located = environment.locateExecutable(candidate, environment.env)
      if (located !== undefined) {
        if (!seen.has(located)) {
          seen.add(located)
          locatedCandidates.push({
            command: located,
            version: versionReader(located, environment.env)
          })
        }
      }
    }
    let selected = locatedCandidates[0]
    for (const candidate of locatedCandidates.slice(1)) {
      if (
        selected?.version !== undefined &&
        candidate.version !== undefined &&
        isCodexVersionNewer(candidate.version, selected.version)
      ) {
        selected = candidate
      }
    }
    if (selected !== undefined) return selected.command

    const binary = definition.detectBinaries[0] ?? "codex"
    throw new Error(`${binary} not found on PATH or in the Codex app`)
  }

  const connect = async (
    definition: HarnessDefinition,
    cwd: string,
    account?: HarnessAccountContext,
    toolGateway?: ToolGatewayConfig
  ): Promise<CodexClient> => {
    const command = locateCodex(definition)
    const client = await connector({
      command,
      cwd,
      env: {
        ...environment.env,
        ...account?.env,
        ...(toolGateway === undefined ? {} : { HERDMAN_MCP_GATEWAY_TOKEN: toolGateway.bearerToken })
      }
    })
    await client.request("initialize", {
      // experimentalApi unlocks turn/start.collaborationMode (Plan mode) and
      // item/tool/requestUserInput.
      capabilities: { experimentalApi: true },
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
    resumeThreadId: string | undefined,
    account?: HarnessAccountContext,
    toolGateway?: ToolGatewayConfig
  ): Promise<CodexSession> => {
    const client = await connect(definition, cwd, account, toolGateway)
    const threadConfig =
      toolGateway === undefined
        ? undefined
        : {
            mcp_servers: {
              [toolGateway.name]: {
                url: toolGateway.url,
                bearer_token_env_var: "HERDMAN_MCP_GATEWAY_TOKEN",
                default_tools_approval_mode: "approve"
              }
            }
          }
    let response: { thread?: { id?: string }; model?: string }
    if (resumeThreadId === undefined) {
      response = await client.request("thread/start", {
        cwd,
        ...(threadConfig === undefined ? {} : { config: threadConfig })
      })
    } else {
      try {
        response = await client.request("thread/resume", {
          cwd,
          threadId: resumeThreadId,
          ...(threadConfig === undefined ? {} : { config: threadConfig })
        })
      } catch {
        // Sessions created by the old codex-acp adapter may not be app-server
        // thread ids; fall back to a fresh thread rather than failing the
        // session outright (history is lost, the session keeps working).
        response = await client.request("thread/start", {
          cwd,
          ...(threadConfig === undefined ? {} : { config: threadConfig })
        })
      }
    }
    const threadId = response.thread?.id
    if (threadId === undefined) {
      client.close()
      throw new Error("codex app-server did not return a thread id")
    }
    const session: CodexSession = {
      activeTurnId: undefined,
      backgroundTerminals: config.backgroundTerminals,
      client,
      collabThreads: new Map(),
      collaborationEngaged: false,
      commandTerminals: new Map(),
      killCommandProcesses: config.killCommandProcesses ?? killCodexCommandProcesses,
      currentEffort: undefined,
      currentModeId: DEFAULT_CODEX_MODE,
      currentModel: sanitizeModelValue(response.model ?? ""),
      currentSpeed: undefined,
      cwd,
      emit,
      interruptRequested: false,
      itemKinds: new Map(),
      itemTitles: new Map(),
      key: resumeThreadId ?? threadId,
      lastEmittedGoal: undefined,
      lastGoalEmitAtMs: 0,
      messagePhases: new Map(),
      models: [],
      pendingGoalSnapshot: undefined,
      pendingPrompt: undefined,
      pendingQuestions: new Map(),
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
        const tiers = Array.isArray(model.serviceTiers)
          ? model.serviceTiers.flatMap((tier) =>
              isRecord(tier) && typeof tier.id === "string" ? [tier.id] : []
            )
          : []
        return [
          {
            defaultEffort:
              typeof model.defaultReasoningEffort === "string"
                ? model.defaultReasoningEffort
                : "medium",
            defaultsToFast: model.defaultServiceTier === CODEX_FAST_TIER,
            efforts,
            name: typeof model.displayName === "string" ? model.displayName : value,
            supportsFast: tiers.includes(CODEX_FAST_TIER),
            value
          }
        ]
      })
      const current = currentCodexModelFor(session)
      if (current !== undefined && session.currentEffort === undefined) {
        session.currentEffort = current.defaultEffort
      }
    } catch {
      session.models = []
    }
    client.onNotification((method, params) => {
      handleNotification(session, method, params)
    })
    client.onRequest((method, params) => serverRequestResponse(session, method, params))
    client.onClose((error) => {
      session.pendingPrompt?.resolve({ stopReason: "cancelled" })
      session.pendingPrompt = undefined
      cancelPendingQuestions(session)
      closeCommandTerminals(session)
      void session.emit({
        kind: "session.error",
        payload: { message: error.message },
        subjectId: session.key
      })
    })
    // A fresh session has no running commands; this snapshot clears stale
    // "running" tasks a client may replay from a previous server process.
    if (config.backgroundTerminals !== undefined) {
      emitCodexBackgroundTasks(session)
    }
    return session
  }

  const configOptionsFor = (session: CodexSession): ReadonlyArray<SessionConfigOption> => {
    const options: Array<SessionConfigOption> = []
    const current = currentCodexModelFor(session)
    if (current !== undefined) {
      options.push({
        category: "model",
        currentValue: current.value,
        id: "model",
        name: "Model",
        options: session.models.map((model) => ({ name: model.name, value: model.value }))
      })
    }
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
    if (current?.supportsFast === true) {
      options.push({
        category: "speed",
        currentValue: effectiveSpeed(session) ?? "standard",
        id: "speed",
        name: "Speed",
        options: [
          { name: "Standard", value: "standard" },
          { description: "Prioritized, faster responses", name: "Fast", value: "fast" }
        ]
      })
    }
    return options
  }

  /// The speed the next turn runs at: the user's pick, else the current
  /// model's catalog default. Undefined when the model has no fast tier.
  const effectiveSpeed = (session: CodexSession): "standard" | "fast" | undefined => {
    const current = currentCodexModelFor(session)
    if (current?.supportsFast !== true) return undefined
    return session.currentSpeed ?? (current.defaultsToFast ? "fast" : "standard")
  }

  const currentCodexModelFor = (session: CodexSession): CodexModel | undefined => {
    if (session.models.length === 0) {
      session.currentModel = sanitizeModelValue(session.currentModel)
      return undefined
    }
    const matched = findKnownModel(session.models, session.currentModel)
    if (matched !== undefined) {
      session.currentModel = matched.value
      return matched
    }
    const fallback = session.models[0]
    if (fallback === undefined) return undefined
    session.currentModel = fallback.value
    session.currentEffort = highestThinkingLevel(fallback.efforts) ?? fallback.defaultEffort
    session.currentSpeed = undefined
    return fallback
  }

  const modesFor = (session: CodexSession): SessionModeState => ({
    availableModes: CODEX_MODES.map((mode) => ({
      canonicalId: mode.canonicalId,
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
      // A held question would block the interrupt from ever completing.
      cancelPendingQuestions(session)
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
      closeCommandTerminals(session)
      session.client.close()
    }),
    prompt: (input) =>
      adapterPromise("prompt", async () => {
        const pending = new Promise<{ stopReason: string }>((resolve) => {
          session.pendingPrompt = { resolve }
        })
        const mode = CODEX_MODES.find((candidate) => candidate.id === session.currentModeId)
        const speed = effectiveSpeed(session)
        // Codex's collaboration mode is sticky server-side: once Plan mode is
        // engaged, every later turn must send an explicit collaboration mode or
        // the model stays in Plan. So after any plan turn we keep sending it,
        // and "default" (any non-plan mode) resets codex back out of Plan —
        // mirroring codex CLI's leave-plan-mode action.
        if (mode?.collaboration === "plan") session.collaborationEngaged = true
        const collaborationMode =
          session.currentModel.length > 0 &&
          (mode?.collaboration !== undefined || session.collaborationEngaged)
            ? {
                collaborationMode: {
                  mode: mode?.collaboration ?? "default",
                  settings: {
                    developer_instructions: null,
                    model: session.currentModel,
                    reasoning_effort: session.currentEffort ?? null
                  }
                }
              }
            : {}
        await session.client.request("turn/start", {
          input: codexInput(normalizePromptInput(input)),
          threadId: session.threadId,
          ...(session.currentModel.length === 0 ? {} : { model: session.currentModel }),
          ...(session.currentEffort === undefined ? {} : { effort: session.currentEffort }),
          ...(speed === undefined
            ? {}
            : { serviceTier: speed === "fast" ? CODEX_FAST_TIER : CODEX_STANDARD_TIER }),
          ...(mode === undefined
            ? {}
            : { approvalPolicy: mode.approvalPolicy, sandboxPolicy: mode.sandboxPolicy }),
          // EXPERIMENTAL collaboration mode: "plan" makes the model propose a
          // plan (streamed as plan items → plan_document) before implementing;
          // "default" (sent once Plan mode has been left) switches it back to
          // coding. Settings.model is required by the wire shape; settings keys
          // stay snake_case (no camelCase rename upstream).
          ...collaborationMode
        })
        return pending
      }),
    setConfigOption: (configId, value) =>
      adapterPromise("setConfigOption", async () => {
        // Applied as sticky turn/start overrides on subsequent turns.
        if (configId === "model") {
          session.currentModel = value
          const model = currentCodexModelFor(session)
          if (
            model !== undefined &&
            (session.currentEffort === undefined || !model.efforts.includes(session.currentEffort))
          ) {
            session.currentEffort = model.defaultEffort
          }
          // Speed picks don't carry across models — fall back to the new
          // model's default tier.
          session.currentSpeed = undefined
        } else if (configId === "effort") {
          session.currentEffort = value
        } else if (configId === "speed") {
          session.currentSpeed = value === "fast" ? "fast" : "standard"
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
      }),
    setGoal: (update: SetGoalUpdate) =>
      adapterPromise("setGoal", async () => {
        // Double-option passthrough: an omitted key keeps the current value,
        // an explicit null clears the token budget.
        const response = await session.client.request<{ goal?: unknown }>("thread/goal/set", {
          threadId: session.threadId,
          ...(update.objective === undefined ? {} : { objective: update.objective }),
          ...(update.status === undefined ? {} : { status: update.status }),
          ...("tokenBudget" in update ? { tokenBudget: update.tokenBudget ?? null } : {})
        })
        const goal = sessionGoalFrom(response.goal)
        if (goal === undefined) {
          throw new Error("codex app-server returned no goal for thread/goal/set")
        }
        await emitGoalSnapshot(session, goal)
        return goal
      }),
    clearGoal: adapterPromise("clearGoal", async () => {
      await session.client.request("thread/goal/clear", { threadId: session.threadId })
      await emitGoalCleared(session)
    }),
    answerQuestion: (questionId, answer) =>
      adapterPromise("answerQuestion", () => answerCodexQuestion(session, questionId, answer))
  })

  return {
    createSession: (
      definition,
      cwd,
      emit,
      account,
      toolGateway
    ): Effect.Effect<CreatedAgentSession, AgentRuntimeError> =>
      adapterPromise("createSession", async () => {
        const session = await startSession(definition, cwd, emit, undefined, account, toolGateway)
        return {
          handle: handleFor(session),
          metadata: {
            configOptions: configOptionsFor(session),
            modes: modesFor(session),
            sessionId: session.key,
            supportsGoals: true
          }
        }
      }),
    id: "codex",
    loadSession: (
      definition,
      agentSessionId,
      cwd,
      emit,
      account,
      toolGateway
    ): Effect.Effect<LoadedAgentSession, AgentRuntimeError> =>
      adapterPromise("loadSession", async () => {
        const session = await startSession(
          definition,
          cwd,
          emit,
          agentSessionId,
          account,
          toolGateway
        )
        return {
          handle: handleFor(session),
          metadata: {
            configOptions: configOptionsFor(session),
            modes: modesFor(session),
            sessionId: session.key,
            supportsGoals: true
          },
          sessionId: session.key
        }
      }),
    // Native sessions from ~/.codex/sessions rollouts — workspace
    // suggestions and "import existing chats" for pre-HerdMan codex users.
    listAgentSessions: () => listCodexAgentSessions(),
    readiness: (definition) => {
      const installed = codexCandidates(definition).some((candidate) =>
        environment.executableExists(candidate, environment.env)
      )
      return installed
        ? { state: "ready" }
        : { detail: "CLI not found on PATH", state: "unavailable" }
    }
  }
}

const readCodexVersion = (command: string, env: NodeJS.ProcessEnv): string | undefined => {
  try {
    const output = execFileSync(command, ["--version"], {
      encoding: "utf8",
      env,
      timeout: 1000
    })
    return codexVersionFromOutput(output)
  } catch {
    return undefined
  }
}

const codexVersionFromOutput = (output: string): string | undefined => {
  const match = output.match(/(?:^|\s)[vV]?(\d+(?:\.\d+)+)(?:-[^\s]+)?/)
  return match?.[1]
}

const isCodexVersionNewer = (candidate: string, current: string): boolean => {
  const lhs = numericVersionComponents(candidate)
  const rhs = numericVersionComponents(current)
  for (let index = 0; index < Math.max(lhs.length, rhs.length); index += 1) {
    const left = lhs[index] ?? 0
    const right = rhs[index] ?? 0
    if (left !== right) return left > right
  }
  return false
}

const numericVersionComponents = (version: string): ReadonlyArray<number> => {
  const normalized = (codexVersionFromOutput(version) ?? version).trim().replace(/^[vV]/, "")
  const base = normalized.split("-")[0] ?? normalized
  return base.split(".").map((part) => Number.parseInt(part, 10) || 0)
}

/// Routes codex's server→client requests: questions and MCP elicitations
/// block on the human's answer; approvals stay auto-accepted (still the seam
/// for a permission UI).
const serverRequestResponse = (
  session: CodexSession,
  method: string,
  params: unknown
): Promise<unknown> => {
  switch (method) {
    case "item/tool/requestUserInput":
      return holdQuestionRequest(session, isRecord(params) ? params : {})
    case "mcpServer/elicitation/request":
      return holdElicitationRequest(session, isRecord(params) ? params : {})
    case "item/commandExecution/requestApproval":
    case "item/fileChange/requestApproval":
    case "item/permissions/requestApproval":
      // Approvals only arrive in modes with approvalPolicy on-request (Ask /
      // Read-only / Plan) — the full-access default never asks.
      return holdApprovalRequest(session, method, isRecord(params) ? params : {})
    default:
      return Promise.reject(new Error(`Unsupported approval request: ${method}`))
  }
}

/// Surfaces a codex approval request as a blocking question: Allow/Deny (plus
/// "Allow for session" on commands) mapping onto the wire decisions. Cancel
/// and turn interrupts answer `cancel`.
const holdApprovalRequest = (
  session: CodexSession,
  method: string,
  params: Record<string, unknown>
): Promise<unknown> => {
  const itemId = typeof params.itemId === "string" ? params.itemId : undefined
  const detail = itemId === undefined ? undefined : session.itemTitles.get(itemId)
  const isCommand = method === "item/commandExecution/requestApproval"
  const spec: QuestionSpec = {
    allowsOther: false,
    id: "approval",
    options: [
      { label: "Allow" },
      ...(isCommand ? [{ label: "Allow for session" }] : []),
      { label: "Deny" }
    ],
    question:
      method === "item/fileChange/requestApproval"
        ? "Allow these file edits?"
        : isCommand
          ? "Allow this command to run?"
          : "Grant the requested permissions?",
    ...(isCommand ? { header: "Command" } : {}),
    ...(method === "item/fileChange/requestApproval" ? { header: "Edits" } : {}),
    ...(method === "item/permissions/requestApproval" ? { header: "Permissions" } : {})
  }
  const questionId = randomUUID()
  void session.emit({
    kind: "session.output",
    payload: {
      questionId,
      questions: [spec],
      sessionUpdate: "question",
      ...(detail === undefined ? {} : { message: detail })
    },
    subjectId: session.key
  })
  return new Promise<unknown>((resolve, reject) => {
    session.pendingQuestions.set(questionId, {
      cancelResponse: { decision: "cancel" },
      questions: [spec],
      reject,
      resolve,
      respond: (answers) => {
        const label = answers[spec.id]?.answers[0]
        const decision =
          label === "Allow"
            ? "accept"
            : label === "Allow for session"
              ? "acceptForSession"
              : "decline"
        return { decision }
      },
      timer: undefined
    })
  })
}

// MARK: questions

/// Emits the question to the client and holds codex's JSON-RPC request open
/// until the human answers (or the auto-resolution window elapses — codex
/// marks such asks non-blocking, so we mirror its TUI and submit empty
/// answers to let the turn continue).
const holdQuestionRequest = (
  session: CodexSession,
  params: Record<string, unknown>
): Promise<unknown> => {
  const questionId = typeof params.itemId === "string" ? params.itemId : randomUUID()
  const questions = questionSpecsFrom(params.questions)
  if (questions.length === 0) {
    return Promise.reject(new Error("requestUserInput carried no questions"))
  }
  const autoResolutionMs =
    typeof params.autoResolutionMs === "number" ? params.autoResolutionMs : undefined
  void session.emit({
    kind: "session.output",
    payload: {
      questionId,
      questions,
      sessionUpdate: "question",
      ...(autoResolutionMs === undefined ? {} : { autoResolutionMs })
    },
    subjectId: session.key
  })
  return new Promise<unknown>((resolve, reject) => {
    const timer =
      autoResolutionMs === undefined
        ? undefined
        : setTimeout(() => {
            const pending = session.pendingQuestions.get(questionId)
            if (pending === undefined) return
            session.pendingQuestions.delete(questionId)
            pending.resolve({ answers: {} })
            void emitQuestionResolved(session, questionId, "autoResolved", questions, undefined)
          }, autoResolutionMs)
    timer?.unref?.()
    session.pendingQuestions.set(questionId, {
      questions,
      reject,
      resolve,
      respond: (answers) => ({
        answers: Object.fromEntries(
          Object.entries(answers).map(([id, entry]) => [
            id,
            {
              answers: [
                ...entry.answers,
                ...(entry.note === undefined || entry.note.length === 0
                  ? []
                  : [`user_note: ${entry.note}`])
              ]
            }
          ])
        )
      }),
      timer
    })
  })
}

/// Emits an MCP server's elicitation as a question and holds the request
/// open. Form fields map onto question specs (enums → options, booleans →
/// Yes/No, string/number → free text); the reply is the structured
/// `{action, content}` MCP expects, with values coerced back to field types.
/// URL-mode elicitations are declined — there is no browser hand-off UX yet.
const holdElicitationRequest = (
  session: CodexSession,
  params: Record<string, unknown>
): Promise<unknown> => {
  const schema = isRecord(params.requestedSchema) ? params.requestedSchema : undefined
  const fields = schema !== undefined ? elicitationFields(schema) : []
  if (params.mode === "url" || fields.length === 0) {
    return Promise.resolve({ action: "decline", content: null })
  }
  const questionId = randomUUID()
  const serverName = typeof params.serverName === "string" ? params.serverName : "MCP server"
  const message = typeof params.message === "string" ? params.message : undefined
  const questions = fields.map((field) => field.spec)
  void session.emit({
    kind: "session.output",
    payload: {
      message: message ?? `${serverName} needs input to continue.`,
      questionId,
      questions,
      sessionUpdate: "question"
    },
    subjectId: session.key
  })
  return new Promise<unknown>((resolve, reject) => {
    session.pendingQuestions.set(questionId, {
      cancelResponse: { action: "cancel", content: null },
      questions,
      reject,
      resolve,
      respond: (answers) => {
        const content: Record<string, unknown> = {}
        for (const field of fields) {
          const entry = answers[field.spec.id]
          if (entry === undefined) continue
          const value = field.coerce(entry)
          if (value !== undefined) {
            content[field.spec.id] = value
          }
        }
        return { action: "accept", content }
      },
      timer: undefined
    })
  })
}

interface ElicitationField {
  readonly spec: QuestionSpec
  /// Coerces the wire answer entry back to the field's schema type; undefined
  /// drops the field from the accepted content.
  readonly coerce: (entry: QuestionAnswerEntry) => unknown
}

/// Lenient flat-object mapping of the MCP elicitation form schema
/// (2025-11-25 `ElicitRequestFormParams`) onto question specs.
const elicitationFields = (schema: Record<string, unknown>): Array<ElicitationField> => {
  if (!isRecord(schema.properties)) return []
  return Object.entries(schema.properties).flatMap(([key, raw]): Array<ElicitationField> => {
    if (!isRecord(raw)) return []
    const title = typeof raw.title === "string" ? raw.title : undefined
    const description = typeof raw.description === "string" ? raw.description : undefined
    const question = description ?? title ?? key
    const base = { id: key, question }

    // Single-select enums: `oneOf: [{const, title}]` or `enum` (+ enumNames).
    const constOptions = Array.isArray(raw.oneOf) ? enumOptions(raw.oneOf) : undefined
    const plainEnum = Array.isArray(raw.enum)
      ? plainEnumOptions(raw.enum, raw.enumNames)
      : undefined
    if (constOptions !== undefined || plainEnum !== undefined) {
      const options = constOptions ?? plainEnum ?? []
      return [
        {
          coerce: (entry) => options.find((option) => option.label === entry.answers[0])?.value,
          spec: { ...base, allowsOther: false, options: options.map(optionSpec) }
        }
      ]
    }
    // Multi-select enums: `type: "array"` with enum-shaped `items`.
    if (raw.type === "array" && isRecord(raw.items)) {
      const items = raw.items
      const options =
        (Array.isArray(items.anyOf) ? enumOptions(items.anyOf) : undefined) ??
        (Array.isArray(items.oneOf) ? enumOptions(items.oneOf) : undefined) ??
        (Array.isArray(items.enum) ? plainEnumOptions(items.enum, items.enumNames) : undefined) ??
        []
      if (options.length === 0) return []
      return [
        {
          coerce: (entry) =>
            entry.answers.flatMap((label) => {
              const value = options.find((option) => option.label === label)?.value
              return value === undefined ? [] : [value]
            }),
          spec: { ...base, allowsOther: false, multiSelect: true, options: options.map(optionSpec) }
        }
      ]
    }
    if (raw.type === "boolean") {
      return [
        {
          coerce: (entry) =>
            entry.answers[0] === "Yes" ? true : entry.answers[0] === "No" ? false : undefined,
          spec: {
            ...base,
            allowsOther: false,
            options: [{ label: "Yes" }, { label: "No" }]
          }
        }
      ]
    }
    if (raw.type === "number" || raw.type === "integer") {
      return [
        {
          coerce: (entry) => {
            const text = entry.note ?? entry.answers[0] ?? ""
            const parsed = Number(text)
            return Number.isFinite(parsed) ? parsed : undefined
          },
          spec: { ...base, allowsOther: true, options: [] }
        }
      ]
    }
    // Strings (and anything unrecognized) become free-text questions.
    return [
      {
        coerce: (entry) => {
          const text = (entry.note ?? entry.answers[0] ?? "").trim()
          return text.length > 0 ? text : undefined
        },
        spec: { ...base, allowsOther: true, options: [] }
      }
    ]
  })
}

interface LabeledValue {
  readonly label: string
  readonly description?: string
  readonly value: string
}

const enumOptions = (entries: ReadonlyArray<unknown>): Array<LabeledValue> | undefined => {
  const options = entries.flatMap((entry) =>
    isRecord(entry) && typeof entry.const === "string"
      ? [
          {
            label: typeof entry.title === "string" ? entry.title : entry.const,
            value: entry.const
          }
        ]
      : []
  )
  return options.length > 0 ? options : undefined
}

const plainEnumOptions = (
  values: ReadonlyArray<unknown>,
  names: unknown
): Array<LabeledValue> | undefined => {
  const labels = Array.isArray(names) ? names : []
  const options = values.flatMap((value, index) =>
    typeof value === "string"
      ? [{ label: typeof labels[index] === "string" ? (labels[index] as string) : value, value }]
      : []
  )
  return options.length > 0 ? options : undefined
}

const optionSpec = (option: LabeledValue): { label: string; description?: string } => ({
  label: option.label,
  ...(option.description === undefined ? {} : { description: option.description })
})

/// Lenient mapping from codex question objects to the wire QuestionSpec.
const questionSpecsFrom = (value: unknown): Array<QuestionSpec> => {
  if (!Array.isArray(value)) return []
  return value.flatMap((entry) => {
    if (!isRecord(entry) || typeof entry.question !== "string") return []
    const options = Array.isArray(entry.options)
      ? entry.options.flatMap((option) =>
          isRecord(option) && typeof option.label === "string"
            ? [
                {
                  label: option.label,
                  ...(typeof option.description === "string"
                    ? { description: option.description }
                    : {})
                }
              ]
            : []
        )
      : []
    return [
      {
        allowsOther: entry.isOther !== false,
        id: typeof entry.id === "string" ? entry.id : randomUUID(),
        options,
        question: entry.question,
        ...(typeof entry.header === "string" ? { header: entry.header } : {}),
        ...(entry.isSecret === true ? { isSecret: true } : {})
      }
    ]
  })
}

const emitQuestionResolved = (
  session: CodexSession,
  questionId: string,
  outcome: "answered" | "cancelled" | "autoResolved",
  questions: ReadonlyArray<QuestionSpec>,
  answers: QuestionAnswer["answers"]
): Promise<void> =>
  session.emit({
    kind: "session.output",
    payload: {
      outcome,
      questionId,
      questions,
      sessionUpdate: "question_resolved",
      ...(answers === undefined ? {} : { answers })
    },
    subjectId: session.key
  })

/// Resolves the human's answer back into the held request via the pending
/// entry's source-specific builder. Cancel either sends the source's
/// dismissal reply (MCP elicitations expect `{action: "cancel"}`) or rejects
/// the JSON-RPC request (requestUserInput — codex tells the model the ask
/// was cancelled).
const answerCodexQuestion = async (
  session: CodexSession,
  questionId: string,
  answer: QuestionAnswer
): Promise<void> => {
  const pending = session.pendingQuestions.get(questionId)
  if (pending === undefined) {
    throw new Error(`No pending question: ${questionId}`)
  }
  session.pendingQuestions.delete(questionId)
  if (pending.timer !== undefined) clearTimeout(pending.timer)
  if (answer.outcome === "cancelled") {
    dismissPendingQuestion(pending, "User dismissed the question without answering")
    await emitQuestionResolved(session, questionId, "cancelled", pending.questions, undefined)
    return
  }
  const answers = answer.answers ?? {}
  pending.resolve(pending.respond(answers))
  await emitQuestionResolved(session, questionId, "answered", pending.questions, answers)
}

const dismissPendingQuestion = (pending: PendingCodexQuestion, reason: string): void => {
  if (pending.cancelResponse !== undefined) {
    pending.resolve(pending.cancelResponse)
  } else {
    pending.reject(new Error(reason))
  }
}

/// Turn interrupts, turn completion, and process close all invalidate any
/// still-pending questions: dismiss them at the source and emit the
/// resolution so clients drop the picker instead of hanging on it.
const cancelPendingQuestions = (session: CodexSession): void => {
  for (const [questionId, pending] of [...session.pendingQuestions]) {
    session.pendingQuestions.delete(questionId)
    if (pending.timer !== undefined) clearTimeout(pending.timer)
    dismissPendingQuestion(pending, "Question cancelled with the turn")
    void emitQuestionResolved(session, questionId, "cancelled", pending.questions, undefined)
  }
}

// MARK: goal mapping

/// Maps a codex `ThreadGoal` (unix-seconds timestamps) onto the wire
/// `SessionGoal`. Lenient like the other decoders: a malformed or
/// unknown-status goal yields undefined and the snapshot is skipped.
const sessionGoalFrom = (value: unknown): SessionGoal | undefined => {
  if (!isRecord(value)) return undefined
  const objective = typeof value.objective === "string" ? value.objective : undefined
  const status =
    typeof value.status === "string" && GOAL_STATUSES.has(value.status)
      ? (value.status as GoalStatus)
      : undefined
  if (objective === undefined || status === undefined) return undefined
  return {
    createdAt: isoFromUnixSeconds(value.createdAt),
    objective,
    status,
    timeUsedSeconds: typeof value.timeUsedSeconds === "number" ? value.timeUsedSeconds : 0,
    tokenBudget: typeof value.tokenBudget === "number" ? value.tokenBudget : null,
    tokensUsed: typeof value.tokensUsed === "number" ? value.tokensUsed : 0,
    updatedAt: isoFromUnixSeconds(value.updatedAt)
  }
}

const isoFromUnixSeconds = (value: unknown): string =>
  new Date((typeof value === "number" ? value : 0) * 1000).toISOString()

/// Whether a snapshot differs from the last emitted one beyond token/time
/// accounting — those changes always reach the wire immediately.
const goalMateriallyChanged = (session: CodexSession, goal: SessionGoal): boolean =>
  session.lastEmittedGoal === undefined ||
  session.lastEmittedGoal.objective !== goal.objective ||
  session.lastEmittedGoal.status !== goal.status ||
  session.lastEmittedGoal.tokenBudget !== goal.tokenBudget

const emitGoalSnapshot = (session: CodexSession, goal: SessionGoal): Promise<void> => {
  session.lastEmittedGoal = goal
  session.lastGoalEmitAtMs = Date.now()
  session.pendingGoalSnapshot = undefined
  return session.emit({
    kind: "session.updated",
    payload: { goal },
    subjectId: session.key
  })
}

const emitGoalCleared = (session: CodexSession): Promise<void> => {
  session.lastEmittedGoal = undefined
  session.pendingGoalSnapshot = undefined
  return session.emit({
    kind: "session.updated",
    payload: { goalCleared: true },
    subjectId: session.key
  })
}

/// `thread/goal/updated` handler: material changes and out-of-band snapshots
/// (turnId null — client set / resume) emit immediately; accounting-only
/// ticks are rate-limited with the freshest snapshot held for the next
/// window or the turn-end flush.
const handleGoalUpdated = (session: CodexSession, payload: Record<string, unknown>): void => {
  const goal = sessionGoalFrom(payload.goal)
  if (goal === undefined) return
  const outOfBand = payload.turnId === null || payload.turnId === undefined
  if (outOfBand || goalMateriallyChanged(session, goal)) {
    void emitGoalSnapshot(session, goal)
    return
  }
  if (Date.now() - session.lastGoalEmitAtMs >= GOAL_ACCOUNTING_INTERVAL_MS) {
    void emitGoalSnapshot(session, goal)
    return
  }
  session.pendingGoalSnapshot = goal
}

const flushPendingGoalSnapshot = (session: CodexSession): Promise<void> => {
  const pending = session.pendingGoalSnapshot
  if (pending === undefined) return Promise.resolve()
  return emitGoalSnapshot(session, pending)
}

// MARK: notification mapping

const handleNotification = (session: CodexSession, method: string, params: unknown): void => {
  const payload = isRecord(params) ? params : {}
  // Every notification is thread-scoped. Collab subagents run as separate
  // threads on the same connection: their items nest under the spawnAgent
  // tool call, their turn lifecycle must NOT drive the session's turn state,
  // and traffic from a thread we can't attribute is dropped rather than mixed
  // into the main transcript.
  const threadId = typeof payload.threadId === "string" ? payload.threadId : undefined
  const isForeign = threadId !== undefined && threadId !== session.threadId
  const parentToolCallId = isForeign ? session.collabThreads.get(threadId) : undefined
  if (isForeign) {
    const routable =
      method === "item/started" ||
      method === "item/completed" ||
      method === "item/agentMessage/delta" ||
      method === "item/reasoning/textDelta" ||
      method === "item/reasoning/summaryTextDelta" ||
      method === "item/fileChange/patchUpdated" ||
      method === "item/commandExecution/outputDelta"
    if (!routable || parentToolCallId === undefined) return
  }
  const parentField = parentToolCallId === undefined ? {} : { parentToolCallId }
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
      // A turn that ends with questions still open (interrupt, failure)
      // invalidates them — clients must not keep showing the picker.
      cancelPendingQuestions(session)
      // Rate-limited goal accounting flushes before the turn closes so the
      // final totals are persisted ahead of the ended event.
      void flushPendingGoalSnapshot(session)
        .then(() =>
          session.emit({
            kind: "session.updated",
            payload: {
              initiatedBy: pending === undefined ? "agent" : "user",
              stopReason,
              turnId,
              turnState: "ended"
            },
            subjectId: session.key
          })
        )
        .then(() => pending?.resolve({ stopReason }))
      break
    }
    case "item/agentMessage/delta": {
      // Finality captured from the item's `item/started` (see wirePhase): lets
      // clients style the final answer correctly from the very first chunk.
      const phase =
        typeof payload.itemId === "string" ? session.messagePhases.get(payload.itemId) : undefined
      void session.emit({
        kind: "session.output",
        payload: {
          content: { text: String(payload.delta ?? ""), type: "text" },
          sessionUpdate: "agent_message_chunk",
          ...(typeof payload.itemId === "string" ? { messageId: payload.itemId } : {}),
          ...(phase === undefined ? {} : { phase }),
          ...parentField
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
          sessionUpdate: "agent_thought_chunk",
          ...parentField
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
            sessionUpdate: "agent_thought_chunk",
            ...parentField
          },
          subjectId: session.key
        })
        break
      }
      if (item.type === "collabAgentToolCall") {
        handleCollabItem(session, item, method === "item/started")
        break
      }
      if (item.type === "subAgentActivity") {
        handleSubAgentActivity(session, item)
        break
      }
      emitItemLifecycle(session, item, method === "item/started", parentToolCallId)
      break
    }
    case "item/commandExecution/outputDelta": {
      const itemId = typeof payload.itemId === "string" ? payload.itemId : undefined
      const delta = typeof payload.delta === "string" ? payload.delta : undefined
      if (itemId === undefined || delta === undefined) break
      session.commandTerminals.get(itemId)?.stream.output(delta)
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
            ...(stats.length === 0 ? {} : { diffStats: stats }),
            ...parentField
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
    case "thread/goal/updated": {
      handleGoalUpdated(session, payload)
      break
    }
    case "thread/goal/cleared": {
      void emitGoalCleared(session)
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

/// Collab tool calls are how a codex agent drives its subagents: `spawnAgent`
/// becomes the visible "Agent" tool call that child-thread items nest under;
/// `closeAgent` settles it. `wait`/`sendInput`/`resumeAgent` are plumbing and
/// stay invisible.
const handleCollabItem = (
  session: CodexSession,
  item: Record<string, unknown>,
  started: boolean
): void => {
  const itemId = typeof item.id === "string" ? item.id : undefined
  if (itemId === undefined) return
  const tool = typeof item.tool === "string" ? item.tool : ""
  const receivers = Array.isArray(item.receiverThreadIds)
    ? item.receiverThreadIds.filter((value): value is string => typeof value === "string")
    : []
  if (tool === "spawnAgent") {
    // Register on both lifecycle edges: the child's items must be attributable
    // from the very first notification.
    for (const receiver of receivers) {
      session.collabThreads.set(receiver, itemId)
    }
    if (started) {
      void session.emit({
        kind: "session.output",
        payload: {
          kind: "agent",
          sessionUpdate: "tool_call",
          status: "in_progress",
          title: collabAgentTitle(item),
          toolCallId: itemId,
          ...(typeof item.prompt === "string" ? { rawInput: { prompt: item.prompt } } : {})
        },
        subjectId: session.key
      })
    } else if (item.status === "failed") {
      void session.emit({
        kind: "session.output",
        payload: { sessionUpdate: "tool_call_update", status: "failed", toolCallId: itemId },
        subjectId: session.key
      })
    }
    // A successful spawn completion means the child is now RUNNING — the
    // Agent call stays open until closeAgent (or turn end settles it).
    return
  }
  if (tool === "closeAgent" && !started && item.status !== "failed") {
    for (const receiver of receivers) {
      const spawnId = session.collabThreads.get(receiver)
      if (spawnId === undefined) continue
      void session.emit({
        kind: "session.output",
        payload: { sessionUpdate: "tool_call_update", status: "completed", toolCallId: spawnId },
        subjectId: session.key
      })
    }
  }
  // wait / sendInput / resumeAgent: no visible rows.
}

const collabAgentTitle = (item: Record<string, unknown>): string => {
  if (typeof item.prompt === "string" && item.prompt.trim().length > 0) {
    return `Agent: ${promptSnippet(item.prompt)}`
  }
  return typeof item.model === "string" && item.model.length > 0 ? `Agent (${item.model})` : "Agent"
}

/// Codex spawn prompts are full instruction blobs, so the title takes a short
/// snippet, cut at a word boundary — a hard slice ends mid-phrase and reads
/// like part of the label ("… Read-only").
const promptSnippet = (prompt: string): string => {
  const line = firstLine(prompt.trim())
  if (line.length <= 48) return line
  const cut = line.slice(0, 48)
  const boundary = cut.lastIndexOf(" ")
  return `${(boundary > 20 ? cut.slice(0, boundary) : cut).trimEnd()}…`
}

/// An interrupted subagent will never produce further output; settle its
/// spawn call as cancelled so nested rows don't spin forever.
const handleSubAgentActivity = (session: CodexSession, item: Record<string, unknown>): void => {
  if (item.kind !== "interrupted") return
  const agentThreadId = typeof item.agentThreadId === "string" ? item.agentThreadId : undefined
  if (agentThreadId === undefined) return
  const spawnId = session.collabThreads.get(agentThreadId)
  if (spawnId === undefined) return
  void session.emit({
    kind: "session.output",
    payload: { sessionUpdate: "tool_call_update", status: "cancelled", toolCallId: spawnId },
    subjectId: session.key
  })
}

/// Maps codex's `MessagePhase` ("commentary" | "final_answer") to the wire's
/// phase vocabulary. Absent/unknown stays undefined — per codex convention
/// untagged messages keep legacy semantics, which on our wire means "let the
/// client render optimistically" rather than asserting finality.
const wirePhase = (raw: unknown): "commentary" | "final" | undefined =>
  raw === "commentary" ? "commentary" : raw === "final_answer" ? "final" : undefined

const emitItemLifecycle = (
  session: CodexSession,
  item: Record<string, unknown>,
  started: boolean,
  parentToolCallId?: string
): void => {
  const itemId = typeof item.id === "string" ? item.id : undefined
  if (itemId === undefined) return
  const type = typeof item.type === "string" ? item.type : ""
  const parentField = parentToolCallId === undefined ? {} : { parentToolCallId }
  const event = (payload: Record<string, unknown>): RuntimeEvent => ({
    kind: "session.output",
    payload: { ...payload, ...parentField },
    subjectId: session.key
  })

  switch (type) {
    case "commandExecution": {
      const command = typeof item.command === "string" ? item.command : ""
      if (started) {
        session.itemKinds.set(itemId, "execute")
        if (command.length > 0) session.itemTitles.set(itemId, command)
        openCommandTerminal(session, itemId, command, item.source)
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
        settleCommandTerminal(session, itemId, item)
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
        session.itemTitles.set(itemId, fileChangeTitle(item.changes, false))
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
    case "plan": {
      // EXPERIMENTAL codex plan-mode proposed-plan document. HerdMan doesn't
      // expose the collaboration-mode toggle yet, but if a plan item arrives
      // it renders as a plan document rather than an opaque tool call. The
      // completed item is authoritative; deltas are ignored.
      if (!started && typeof item.text === "string" && item.text.length > 0) {
        void session.emit(
          event({
            markdown: item.text,
            sessionUpdate: "plan_document"
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
            toolCallId: itemId,
            ...(item.arguments === undefined ? {} : { rawInput: item.arguments })
          })
        )
      } else {
        void session.emit(
          event({
            sessionUpdate: "tool_call_update",
            status: item.status === "failed" ? "failed" : "completed",
            toolCallId: itemId,
            ...(item.result !== undefined && item.result !== null
              ? { rawOutput: item.result }
              : item.error !== undefined && item.error !== null
                ? { rawOutput: item.error }
                : {})
          })
        )
      }
      break
    }
    case "webSearch": {
      // The started item often lacks the query — codex fills it in as the
      // model generates the call — so the completed item re-titles the call
      // with the authoritative query.
      const query = typeof item.query === "string" && item.query.length > 0 ? item.query : undefined
      const title =
        query !== undefined
          ? `Searched for ${query}`
          : started
            ? "Searching the web"
            : "Searched the web"
      if (started) {
        void session.emit(
          event({
            // Not ACP vocabulary — HerdMan's own extension so clients can
            // phrase web searches as searches instead of fetches.
            kind: "web_search",
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
            status: "completed",
            title,
            toolCallId: itemId
          })
        )
      }
      break
    }
    case "agentMessage": {
      // Text already streamed via item/agentMessage/delta; the lifecycle only
      // carries the message's phase (harmony commentary vs final answer).
      const phase = wirePhase(item.phase)
      if (started) {
        if (phase !== undefined) session.messagePhases.set(itemId, phase)
        break
      }
      // Completion can reveal a phase the started item lacked (backends that
      // tag only the finished item). A zero-length chunk retro-tags the span
      // clients already streamed; skip when the deltas were tagged all along.
      if (phase !== undefined && session.messagePhases.get(itemId) !== phase) {
        void session.emit(
          event({
            content: { text: "", type: "text" },
            messageId: itemId,
            phase,
            sessionUpdate: "agent_message_chunk"
          })
        )
      }
      session.messagePhases.delete(itemId)
      break
    }
    default:
      break
  }
}

// MARK: command terminal mirrors

/// Starts a read-only terminal mirror for a command execution. Codex owns the
/// process — we only see its output deltas — so the mirror accepts no input;
/// kill is best-effort via the codex process tree (the protocol has no
/// terminate for agent-run commands). Commands that outlive the promotion
/// delay surface in the `backgroundTasks` snapshot as attachable terminal tabs.
const openCommandTerminal = (
  session: CodexSession,
  itemId: string,
  command: string,
  source: unknown
): void => {
  const integration = session.backgroundTerminals
  if (integration === undefined || session.commandTerminals.has(itemId)) return
  const terminalKey = backgroundTerminalKey(session.key, itemId)
  const codexPid = session.client.pid
  const stream = integration.registry.register(terminalKey, {
    ...(codexPid === undefined || command.length === 0
      ? {}
      : {
          kill: () => {
            void session.killCommandProcesses(codexPid, command).catch(() => undefined)
          }
        })
  })
  const terminal: CodexCommandTerminal = {
    description: command.length > 0 ? firstLine(command) : "command",
    itemId,
    promoted: false,
    promotionTimer: undefined,
    stream,
    terminalKey
  }
  session.commandTerminals.set(itemId, terminal)
  // unifiedExecStartup is codex explicitly opening a persistent shell — its
  // background-process mechanism — so the tab shows up immediately. Plain
  // agent commands prove themselves by outliving the promotion delay.
  if (source === "unifiedExecStartup") {
    terminal.promoted = true
    emitCodexBackgroundTasks(session)
    return
  }
  terminal.promotionTimer = setTimeout(() => {
    terminal.promotionTimer = undefined
    terminal.promoted = true
    emitCodexBackgroundTasks(session)
  }, integration.promotionDelayMs ?? DEFAULT_PROMOTION_DELAY_MS)
}

const settleCommandTerminal = (
  session: CodexSession,
  itemId: string,
  item: Record<string, unknown>
): void => {
  const terminal = session.commandTerminals.get(itemId)
  if (terminal === undefined) return
  session.commandTerminals.delete(itemId)
  if (terminal.promotionTimer !== undefined) {
    clearTimeout(terminal.promotionTimer)
    terminal.promotionTimer = undefined
  }
  terminal.stream.exit(typeof item.exitCode === "number" ? item.exitCode : undefined)
  if (terminal.promoted) {
    // The tab stays attachable for scrollback; the task itself is done.
    emitCodexBackgroundTasks(session)
  } else {
    // Short-lived command: nothing was ever surfaced, leave nothing behind.
    terminal.stream.remove()
  }
}

const emitCodexBackgroundTasks = (session: CodexSession): void => {
  const backgroundTasks = [...session.commandTerminals.values()]
    .filter((terminal) => terminal.promoted)
    .map((terminal) => ({
      description: terminal.description,
      id: terminal.itemId,
      // Codex owns the process; the mirror can neither write nor kill.
      readOnly: true,
      status: "running",
      taskType: "shell",
      terminalKey: terminal.terminalKey,
      toolUseId: terminal.itemId
    }))
  void session.emit({
    kind: "session.updated",
    payload: { backgroundTasks },
    subjectId: session.key
  })
}

/// Connection teardown: the codex process (and every command it ran) is gone;
/// exit the mirrors so attached tabs see the stream end.
const closeCommandTerminals = (session: CodexSession): void => {
  for (const terminal of [...session.commandTerminals.values()]) {
    if (terminal.promotionTimer !== undefined) {
      clearTimeout(terminal.promotionTimer)
      terminal.promotionTimer = undefined
    }
    terminal.stream.exit(undefined)
    if (!terminal.promoted) {
      terminal.stream.remove()
    }
  }
  session.commandTerminals.clear()
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
