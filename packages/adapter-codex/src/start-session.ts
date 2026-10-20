import {
  sanitizeModelValue,
  type HarnessAccountContext,
  type HarnessDefinition,
  type ProviderEnvironment,
  type RuntimeEmit,
  type ToolGatewayConfig
} from "@codevisor/agent-runtime"

import type { CodexClient } from "./client.js"
import { configuredMcpServerNames, NATIVE_AUTOMATION_MCP_SERVERS } from "./config-file.js"
import { isRecord } from "./internal.js"
import { CODEX_FAST_TIER, currentCodexModelFor, DEFAULT_CODEX_MODE } from "./models.js"
import { handleNotification } from "./notifications.js"
import { cancelPendingQuestions, serverRequestResponse } from "./questions.js"
import type { CodexSession } from "./session.js"
import {
  DISABLED_CODEX_PLUGIN,
  NATIVE_CODEX_PLUGIN_SKILL_NAMES,
  refreshCodexSkills
} from "./skills.js"
import { CodexTitleGenerator } from "./title-generation.js"

export interface CodexStartSessionDeps {
  readonly connect: (
    definition: HarnessDefinition,
    cwd: string,
    account?: HarnessAccountContext,
    toolGateway?: ToolGatewayConfig
  ) => Promise<CodexClient>
  readonly environment: ProviderEnvironment
  readonly readConfigFile: (path: string) => string | undefined
}

export const makeStartSession = ({
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
    const configuredServers =
      toolGateway === undefined
        ? undefined
        : configuredMcpServerNames({ ...environment.env, ...account?.env }, readConfigFile)
    const nativeAutomationDisables = NATIVE_AUTOMATION_MCP_SERVERS.filter(
      (name) => configuredServers?.has(name) ?? false
    )
    const threadConfig = {
      plugins: {
        [DISABLED_CODEX_PLUGIN]: { enabled: false }
      },
      skills: {
        bundled: { enabled: false },
        config: NATIVE_CODEX_PLUGIN_SKILL_NAMES.map((name) => ({ name, enabled: false }))
      },
      "features.browser_use": false,
      "features.browser_use_external": false,
      "features.browser_use_full_cdp_access": false,
      "features.computer_use": false,
      "features.in_app_browser": false,
      ...(toolGateway === undefined
        ? {}
        : {
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
          })
    }
    let response: unknown
    if (resumeThreadId === undefined) {
      response = await client.request("thread/start", {
        cwd,
        config: threadConfig
      })
    } else {
      response = await client.request("thread/resume", {
        cwd,
        threadId: resumeThreadId,
        config: threadConfig
      })
    }

    const threadId =
      isRecord(response) && isRecord(response.thread) && typeof response.thread.id === "string"
        ? response.thread.id
        : undefined
    if (threadId === undefined) {
      client.close()
      throw new Error("codex app-server did not return a thread id")
    }
    const session: CodexSession = {
      activeTurnId: undefined,
      asyncQuestion: undefined,
      heldTurnId: undefined,
      latestContext: undefined,
      latestUsageLimits: undefined,
      client,
      collabRunTurns: new Map(),
      collabThreads: new Map(),
      collaborationEngaged: false,
      currentEffort: undefined,
      currentModeId: DEFAULT_CODEX_MODE,
      currentModel: sanitizeModelValue(
        isRecord(response) && typeof response.model === "string" ? response.model : ""
      ),
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
      skills: undefined,
      pendingGoalSnapshot: undefined,
      pendingPrompt: undefined,
      pendingTurnError: undefined,
      pendingQuestions: new Map(),
      threadId
    }
    try {
      const modelList = await client.request("model/list", {})
      const listed = isRecord(modelList) && Array.isArray(modelList.data) ? modelList.data : []
      session.models = listed.flatMap((model: unknown) => {
        if (!isRecord(model) || model.hidden === true) return []
        const value = typeof model.model === "string" ? model.model : undefined
        if (value === undefined) return []
        const efforts = Array.isArray(model.supportedReasoningEfforts)
          ? model.supportedReasoningEfforts.flatMap((option) =>
              isRecord(option) && typeof option.reasoningEffort === "string"
                ? [option.reasoningEffort]
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
    await refreshCodexSkills(session, false)
    client.onNotification((method, params) => {
      handleNotification(session, method, params)
    })
    session.titleGenerator = new CodexTitleGenerator(
      client,
      threadId,
      cwd,
      resumeThreadId !== undefined
    )
    client.onRequest((method, params, signal) =>
      serverRequestResponse(session, method, params, signal)
    )
    client.onClose((error) => {
      session.titleGenerator?.close()
      session.pendingPrompt?.resolve({ stopReason: "cancelled" })
      session.pendingPrompt = undefined
      cancelPendingQuestions(session)
      void session.emit({
        kind: "session.error",
        payload: { message: error.message },
        subjectId: session.key
      })
    })
    return session
  }
  return startSession
}
