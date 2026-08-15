import {
  sanitizeModelValue,
  type BackgroundTerminalIntegration,
  type HarnessAccountContext,
  type HarnessDefinition,
  type ProviderEnvironment,
  type RuntimeEmit,
  type ToolGatewayConfig
} from "@codevisor/agent-runtime"
import type { CodexClient } from "./client.js"
import { closeCommandTerminals, emitCodexBackgroundTasks } from "./command-terminals.js"
import { configuredMcpServerNames, NATIVE_AUTOMATION_MCP_SERVERS } from "./config-file.js"
import { isRecord } from "./internal.js"
import { CODEX_FAST_TIER, currentCodexModelFor, DEFAULT_CODEX_MODE } from "./models.js"
import { handleNotification } from "./notifications.js"
import { killCodexCommandProcesses, type CodexCommandKiller } from "./process-kill.js"
import { cancelPendingQuestions, serverRequestResponse } from "./questions.js"
import type { CodexSession } from "./session.js"

export interface CodexStartSessionDeps {
  readonly config: {
    readonly backgroundTerminals?: BackgroundTerminalIntegration
    readonly killCommandProcesses?: CodexCommandKiller
  }
  readonly connect: (
    definition: HarnessDefinition,
    cwd: string,
    account?: HarnessAccountContext,
    toolGateway?: ToolGatewayConfig
  ) => Promise<CodexClient>
  readonly environment: ProviderEnvironment
  readonly readConfigFile: (path: string) => string | undefined
}

/// Session bootstrap extracted from makeCodexProvider as a deps-factory (the
/// makeSkillsOperations pattern): the startSession body is unchanged, its
/// closed-over provider dependencies are injected.
export const makeStartSession = ({
  config,
  connect,
  environment,
  readConfigFile
}: CodexStartSessionDeps) => {
  const startSession = async (
    definition: HarnessDefinition,
    cwd: string,
    emit: RuntimeEmit,
    resumeThreadId: string | undefined,
    account?: HarnessAccountContext,
    toolGateway?: ToolGatewayConfig
  ): Promise<CodexSession> => {
    const client = await connect(definition, cwd, account, toolGateway)
    // Disable stubs may only name servers the machine's config.toml already
    // defines: overrides deep-merge into it, and a bare `{ enabled: false }`
    // for an undefined server creates a transport-less entry the app-server
    // rejects at config load ("invalid transport in `mcp_servers.…`").
    // Machines without the Codex desktop app have no such entries — and
    // nothing to disable.
    const configuredServers =
      toolGateway === undefined
        ? undefined
        : configuredMcpServerNames({ ...environment.env, ...account?.env }, readConfigFile)
    const nativeAutomationDisables = NATIVE_AUTOMATION_MCP_SERVERS.filter(
      (name) => configuredServers?.has(name) ?? false
    )
    const threadConfig =
      toolGateway === undefined
        ? undefined
        : {
            // Keep the native automation skills and their transports out of
            // Codevisor-owned threads without changing the user's global Codex
            // settings. Plugin enablement itself is resolved before thread
            // overrides, while skill rules and MCP server flags are honored here.
            skills: {
              config: [
                { name: "computer-use:computer-use", enabled: false },
                { name: "browser:control-in-app-browser", enabled: false },
                { name: "chrome:control-chrome", enabled: false }
              ]
            },
            features: {
              browser_use: false,
              browser_use_external: false,
              browser_use_full_cdp_access: false,
              computer_use: false,
              in_app_browser: false
            },
            mcp_servers: {
              ...Object.fromEntries(
                nativeAutomationDisables.map((name) => [name, { enabled: false }])
              ),
              [toolGateway.name]: {
                url: toolGateway.url,
                bearer_token_env_var: "CODEVISOR_MCP_GATEWAY_TOKEN",
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
      lastHarnessTitle: undefined,
      lastEmittedGoal: undefined,
      lastGoalEmitAtMs: 0,
      messagePhases: new Map(),
      models: [],
      pendingGoalSnapshot: undefined,
      pendingPrompt: undefined,
      pendingTurnError: undefined,
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
    client.onRequest((method, params, signal) =>
      serverRequestResponse(session, method, params, signal)
    )
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
  return startSession
}
