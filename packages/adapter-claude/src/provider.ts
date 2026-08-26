import {
  getSessionInfo as sdkGetSessionInfo,
  listSessions as sdkListSessions,
  query as sdkQuery
} from "@anthropic-ai/claude-agent-sdk"
import { isoTimestamp } from "@codevisor/api"
import { execFile } from "node:child_process"
import { readFileSync } from "node:fs"
import { Effect } from "effect"
import {
  adapterPromise,
  listClaudeAgentSessions,
  preferHarnessSessionTitles,
  type AgentProvider,
  type AgentRuntimeError,
  type AgentSessionSummary,
  type BackgroundTerminalIntegration,
  type CreatedAgentSession,
  type HarnessDefinition,
  type LoadedAgentSession,
  type ProviderEnvironment
} from "@codevisor/agent-runtime"
import { metadataFor } from "./models.js"
import { makeClaudeSessionHandle } from "./session-handle.js"
import type { ClaudeQueryFn } from "./session.js"
import { makeStartSession } from "./start-session.js"
import { claudeUsageLimitsFrom } from "./usage.js"

/// Claude Code versions older than this predate the control-protocol features
/// the Agent SDK relies on (streaming input, setModel/setPermissionMode).
const MINIMUM_CLAUDE_VERSION = "2.0.0"

export interface ClaudeProviderConfig {
  /// Injectable for tests: scripted SDK message streams instead of a real CLI.
  readonly queryFn?: ClaudeQueryFn
  readonly getSessionInfo?: typeof sdkGetSessionInfo
  readonly listSdkSessions?: typeof sdkListSessions
  readonly scanAgentSessions?: () => Promise<ReadonlyArray<AgentSessionSummary>>
  readonly readFile?: (path: string) => string | undefined
  readonly checkVersion?: (claudePath: string) => Promise<string>
  /// Bounded wait for Claude to produce its normal terminal result after an
  /// interrupt. Exposed for deterministic unit tests.
  readonly cancelGraceMs?: number
  /// When set (and `wrapCommand` is present), background Bash commands are
  /// rewritten to tee their output through a server-owned terminal so clients
  /// can attach to the live process; foreground commands are untouched.
  readonly backgroundTerminals?: BackgroundTerminalIntegration
}

export const makeClaudeProvider = (
  environment: ProviderEnvironment,
  config: ClaudeProviderConfig = {}
): AgentProvider => {
  const queryFn = config.queryFn ?? ((input) => sdkQuery(input))
  const getSessionInfo = config.getSessionInfo ?? sdkGetSessionInfo
  const listSdkSessions = config.listSdkSessions ?? sdkListSessions
  const scanAgentSessions = config.scanAgentSessions ?? (() => listClaudeAgentSessions())
  const readFile =
    config.readFile ??
    ((path: string): string | undefined => {
      try {
        return readFileSync(path, "utf8")
      } catch {
        return undefined
      }
    })
  const checkVersion = config.checkVersion ?? runClaudeVersion
  const wrapCommand = config.backgroundTerminals?.wrapCommand
  const cancelGraceMs = config.cancelGraceMs ?? 1_500
  const versionCache = new Map<string, string>()

  const locateClaude = (definition: HarnessDefinition): string => {
    const binary = definition.detectBinaries[0] ?? "claude"
    const located = environment.locateExecutable(binary, environment.env)
    if (located === undefined) {
      throw new Error(`${binary} not found on PATH`)
    }
    return located
  }

  const guardVersion = async (claudePath: string): Promise<void> => {
    let version = versionCache.get(claudePath)
    if (version === undefined) {
      version = await checkVersion(claudePath)
      versionCache.set(claudePath, version)
    }
    if (compareVersions(version, MINIMUM_CLAUDE_VERSION) < 0) {
      throw new Error(
        `Claude Code ${version} is older than the required ${MINIMUM_CLAUDE_VERSION}. Update with: claude update`
      )
    }
  }

  const startSession = makeStartSession({
    environment,
    getSessionInfo,
    guardVersion,
    locateClaude,
    queryFn,
    readFile,
    wrapCommand
  })
  const handleFor = makeClaudeSessionHandle(cancelGraceMs)

  return {
    createSession: (
      definition,
      cwd,
      emit,
      account,
      toolGateway,
      sessionOptions
    ): Effect.Effect<CreatedAgentSession, AgentRuntimeError> =>
      adapterPromise("createSession", async () => {
        const session = await startSession(
          definition,
          cwd,
          emit,
          undefined,
          account,
          toolGateway,
          sessionOptions
        )
        return {
          handle: handleFor(session),
          metadata: { sessionId: session.key, ...metadataFor(session) }
        }
      }),
    id: "claude",
    // Native sessions from ~/.claude/projects — workspace suggestions and
    // "import existing chats" for users who ran the CLI before Codevisor.
    listAgentSessions: async () => {
      const fallback = await scanAgentSessions()
      try {
        const sessions = await listSdkSessions()
        return preferHarnessSessionTitles(
          fallback,
          sessions.map((session) => {
            const title = session.customTitle ?? session.summary
            return { sessionId: session.sessionId, ...(title === undefined ? {} : { title }) }
          })
        )
      } catch {
        return fallback
      }
    },
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
          metadata: { sessionId: session.key, ...metadataFor(session) },
          sessionId: session.key
        }
      }),
    readUsageLimits: (definition, cwd, account) =>
      adapterPromise("readUsageLimits", async () => {
        const session = await startSession(
          definition,
          cwd,
          () => Promise.resolve(),
          undefined,
          account
        )
        let timeout: ReturnType<typeof setTimeout> | undefined
        try {
          const usage = await Promise.race([
            session.q.usage_EXPERIMENTAL_MAY_CHANGE_DO_NOT_RELY_ON_THIS_API_YET(),
            new Promise<never>(
              (_, reject) =>
                (timeout = setTimeout(
                  () => reject(new Error("Claude usage request timed out")),
                  10_000
                ))
            )
          ])
          return claudeUsageLimitsFrom(usage)
        } catch (error) {
          return {
            detail:
              error instanceof Error
                ? error.message
                : "Claude account usage limits are unavailable.",
            fetchedAt: isoTimestamp(),
            harnessId: "claude-code",
            state: "unavailable" as const,
            windows: []
          }
        } finally {
          if (timeout !== undefined) clearTimeout(timeout)
          session.abort.abort()
        }
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

const compareVersions = (left: string, right: string): number => {
  const leftParts = left.split(".").map((part) => Number.parseInt(part, 10) || 0)
  const rightParts = right.split(".").map((part) => Number.parseInt(part, 10) || 0)
  for (let index = 0; index < Math.max(leftParts.length, rightParts.length); index += 1) {
    const difference = (leftParts[index] ?? 0) - (rightParts[index] ?? 0)
    if (difference !== 0) return difference < 0 ? -1 : 1
  }
  return 0
}

/* v8 ignore start -- exercised against a live claude binary, not in unit tests. */
const runClaudeVersion = (claudePath: string): Promise<string> =>
  new Promise((resolvePromise, rejectPromise) => {
    execFile(claudePath, ["--version"], { timeout: 5000 }, (error, stdout) => {
      if (error !== null) {
        rejectPromise(new Error(`claude --version failed: ${error.message}`))
        return
      }
      const match = /(\d+\.\d+\.\d+)/.exec(stdout)
      if (match?.[1] === undefined) {
        rejectPromise(new Error(`Could not parse claude version from: ${stdout.trim()}`))
        return
      }
      resolvePromise(match[1])
    })
  })
/* v8 ignore stop */
