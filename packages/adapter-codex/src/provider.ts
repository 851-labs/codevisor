/// Assembly surface for the Codex provider: the modules below were split out
/// of the original monolithic provider.ts; everything previously public is
/// re-exported here so index.ts and all consumers stay unchanged.
import { isoTimestamp } from "@codevisor/api"
import { Effect } from "effect"
import {
  adapterPromise,
  listCodexAgentSessions,
  preferHarnessSessionTitles,
  type AgentProvider,
  type AgentRuntimeError,
  type AgentSessionSummary,
  type BackgroundTerminalIntegration,
  type CreatedAgentSession,
  type HarnessAccountContext,
  type HarnessDefinition,
  type HarnessSessionTitle,
  type LoadedAgentSession,
  type ProviderEnvironment,
  type ToolGatewayConfig
} from "@codevisor/agent-runtime"
import { spawnCodexClient, type CodexClient, type CodexConnector } from "./client.js"
import { defaultConfigFileReader } from "./config-file.js"
import { isRecord } from "./internal.js"
import { configOptionsFor, modesFor } from "./models.js"
import { codexThreadTitle } from "./notifications.js"
import type { CodexCommandKiller } from "./process-kill.js"
import { handleFor } from "./session-handle.js"
import { makeStartSession } from "./start-session.js"
import { codexUsageLimitsFrom } from "./usage.js"
import { isCodexVersionNewer, readCodexVersion } from "./version.js"

export { GOAL_ACCOUNTING_INTERVAL_MS } from "./goals.js"
export { codexUsageLimitsFrom }

export interface CodexProviderConfig {
  /// Injectable for tests: scripted app-server sessions instead of a spawned
  /// codex binary.
  readonly connector?: CodexConnector
  readonly scanAgentSessions?: () => Promise<ReadonlyArray<AgentSessionSummary>>
  /// Injectable for tests: reads a resolved Codex binary's version.
  readonly versionReader?: (command: string, env: NodeJS.ProcessEnv) => string | undefined
  /// Injectable for tests: reads the codex home's `config.toml` text, or
  /// `undefined` when the file is missing or unreadable.
  readonly configFileReader?: (path: string) => string | undefined
  /// When set, command executions mirror their streamed output
  /// (`item/commandExecution/outputDelta`) into server-owned terminals;
  /// commands that outlive the promotion delay surface as terminal tabs.
  /// Codex owns the processes, so the mirrors are read-only for input; kill
  /// is best-effort via the codex process tree (see process-kill.ts).
  readonly backgroundTerminals?: BackgroundTerminalIntegration
  /// Injectable for tests: the best-effort process-tree kill.
  readonly killCommandProcesses?: CodexCommandKiller
}

export const makeCodexProvider = (
  environment: ProviderEnvironment,
  config: CodexProviderConfig = {}
): AgentProvider => {
  const connector = config.connector ?? spawnCodexClient
  const scanAgentSessions = config.scanAgentSessions ?? (() => listCodexAgentSessions())
  const versionReader = config.versionReader ?? readCodexVersion
  const readConfigFile = config.configFileReader ?? defaultConfigFileReader

  // PATH first, then fallbackPaths. When both the user CLI and Codex.app
  // bundle are present, compare resolved binary versions and run the newer
  // app-server so Codevisor sees the newest Codex model catalog.
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
        ...(toolGateway === undefined
          ? {}
          : {
              CODEVISOR_MCP_GATEWAY_TOKEN: toolGateway.bearerToken,
              // Resumed pre-rename threads may still reference this env key.
              HERDMAN_MCP_GATEWAY_TOKEN: toolGateway.bearerToken
            })
      }
    })
    await client.request("initialize", {
      // experimentalApi unlocks turn/start.collaborationMode (Plan mode) and
      // item/tool/requestUserInput.
      capabilities: { experimentalApi: true },
      clientInfo: { name: "Codevisor", title: "Codevisor", version: "0.1.0" }
    })
    // The server rejects all other requests until this lands.
    client.notify("initialized")
    return client
  }

  const listHarnessSessionTitles = async (
    definition: HarnessDefinition,
    sessions: ReadonlyArray<AgentSessionSummary>,
    account?: HarnessAccountContext
  ): Promise<ReadonlyArray<HarnessSessionTitle>> => {
    if (sessions.length === 0) return []
    const client = await connect(definition, sessions[0]!.cwd, account)
    const remaining = new Set(sessions.map((session) => session.sessionId))
    const titles: HarnessSessionTitle[] = []
    try {
      // Archived threads live behind a separate filter upstream. Scan both
      // buckets, newest activity first, and stop as soon as every JSONL
      // fallback session has been matched.
      for (const archived of [false, true]) {
        let cursor: string | undefined
        for (let page = 0; page < 50 && remaining.size > 0; page += 1) {
          const response: unknown = await client.request("thread/list", {
            archived,
            limit: 100,
            sortKey: "updated_at",
            ...(cursor === undefined ? {} : { cursor })
          })
          if (!isRecord(response) || !Array.isArray(response.data)) break
          for (const value of response.data) {
            if (!isRecord(value) || typeof value.id !== "string" || !remaining.has(value.id)) {
              continue
            }
            remaining.delete(value.id)
            const title = codexThreadTitle(value)
            titles.push({ sessionId: value.id, ...(title === undefined ? {} : { title }) })
          }
          const next = typeof response.nextCursor === "string" ? response.nextCursor : undefined
          if (next === undefined || next.length === 0 || next === cursor) break
          cursor = next
        }
      }
      return titles
    } finally {
      client.close()
    }
  }

  const startSession = makeStartSession({ config, connect, environment, readConfigFile })

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
    // suggestions and "import existing chats" for pre-Codevisor codex users.
    listAgentSessions: async (definition, account) => {
      const fallback = await scanAgentSessions()
      try {
        return preferHarnessSessionTitles(
          fallback,
          await listHarnessSessionTitles(definition, fallback, account)
        )
      } catch {
        return fallback
      }
    },
    readUsageLimits: (definition, cwd, account) =>
      adapterPromise("readUsageLimits", async () => {
        const client = await connect(definition, cwd, account)
        try {
          return codexUsageLimitsFrom(await client.request("account/rateLimits/read", {}))
        } catch (error) {
          return {
            detail:
              error instanceof Error
                ? error.message
                : "Codex account usage limits are unavailable.",
            fetchedAt: isoTimestamp(),
            harnessId: "codex",
            state: "unavailable" as const,
            windows: []
          }
        } finally {
          client.close()
        }
      }),
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
