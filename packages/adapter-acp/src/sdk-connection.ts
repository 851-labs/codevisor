import * as acp from "@agentclientprotocol/sdk"
import type { NewSessionResponse } from "@agentclientprotocol/sdk"
import type { SessionConfigOption } from "@codevisor/api"
import {
  adapterPromise,
  clampFailureDetail,
  normalizePromptInput,
  runtimeEffect,
  summarizeProcessFailure,
  type AgentSessionMetadata,
  type AgentSessionSummary,
  type QuestionAnswer,
  type ToolGatewayConfig
} from "@codevisor/agent-runtime"
import {
  acpConfigSelection,
  normalizeAcpConfigOptions,
  sessionMetadata,
  type AcpSessionMetadataResponse
} from "./config-options.js"
import type { AcpAgentConnection } from "./connection.js"
import { isGenericConnectionClose } from "./internal.js"
import { extractPiStartupInfo } from "./pi.js"
import { acpPrompt, type AcpPromptCapabilities } from "./prompt.js"

export interface AcpQuestionControls {
  readonly answerQuestion: (
    sessionId: string,
    questionId: string,
    answer: QuestionAnswer
  ) => Promise<void>
  readonly cancelQuestions: (sessionId: string | undefined) => void
}

export interface AcpAuthControls {
  readonly methods: ReadonlyArray<{
    readonly id: string
    readonly name: string
    readonly description?: string
  }>
  readonly canLogout: boolean
}

export interface AcpSetConfigOptionContext {
  readonly connection: acp.ClientConnection
  readonly sessionId: string
  readonly configId: string
  readonly value: string
}

export interface AcpConnectionExtensionContext {
  readonly connection: acp.ClientConnection
  readonly questions?: AcpQuestionControls
}

/// Provider-neutral customization points for ACP-backed native adapters. The
/// generic connection remains responsible for protocol methods; adapters can
/// enrich metadata, handle private configuration routes, or decorate the
/// normalized connection with additional capabilities.
export interface AcpSdkConnectionCustomization {
  readonly customizeSessionMetadata?: (
    sessionId: string,
    response: AcpSessionMetadataResponse,
    metadata: AgentSessionMetadata
  ) => AgentSessionMetadata
  readonly setConfigOption?: (
    context: AcpSetConfigOptionContext
  ) => Promise<ReadonlyArray<SessionConfigOption> | undefined>
  readonly extendConnection?: (
    connection: AcpAgentConnection,
    context: AcpConnectionExtensionContext
  ) => AcpAgentConnection
}

export interface AcpSdkConnectionOptions {
  readonly terminate?: () => void
  readonly promptCapabilities?: AcpPromptCapabilities
  readonly questions?: AcpQuestionControls
  readonly auth?: AcpAuthControls
  readonly piStartupInfoBySession?: Map<string, string>
  readonly piSessionError?: (sessionId: string) => Promise<string | undefined>
  readonly harnessId?: string
  readonly customization?: AcpSdkConnectionCustomization
}

/* v8 ignore start -- stdio ACP adapter is exercised by integration/packaging smoke tests. */
export const sdkConnection = (
  connection: acp.ClientConnection,
  stderr: () => string,
  options: AcpSdkConnectionOptions = {}
): AcpAgentConnection => {
  connection.closed.catch(() => undefined)
  const terminate = options.terminate ?? (() => undefined)
  const promptCapabilities = options.promptCapabilities ?? {}
  const questions = options.questions
  const auth = options.auth ?? { methods: [], canLogout: false }

  const mcpServers = (toolGateway: ToolGatewayConfig | undefined) =>
    toolGateway === undefined
      ? []
      : [
          {
            type: "http" as const,
            name: toolGateway.name,
            url: toolGateway.url,
            headers: [{ name: "Authorization", value: `Bearer ${toolGateway.bearerToken}` }]
          }
        ]

  const base: AcpAgentConnection = {
    probeAuth: (cwd) =>
      adapterPromise("probeAuth", async () => {
        try {
          await connection.agent.request(acp.methods.agent.session.new, { cwd, mcpServers: [] })
          return {
            state:
              auth.methods.length === 0 ? ("notRequired" as const) : ("authenticated" as const),
            methods: auth.methods,
            canLogout: auth.canLogout
          }
        } catch (cause) {
          const error = cause as { code?: number; message?: string }
          if (
            error.code === -32000 ||
            error.message?.toLowerCase().includes("authentication required")
          ) {
            return {
              state: "unauthenticated" as const,
              methods: auth.methods,
              canLogout: auth.canLogout
            }
          }
          // `detail` is rendered as the harness row's subtitle during
          // onboarding, so it must stay a single short sentence even when the
          // underlying CLI crashed and its stderr leaked into the message.
          //
          // When a CLI dies on launch the SDK sees EOF on the pipes and rejects
          // pending requests with a bare "ACP connection closed", which races
          // ahead of our own close error and says nothing about the cause. The
          // process's stderr does, so prefer it whenever the message is that
          // generic placeholder.
          const message = cause instanceof Error ? cause.message : String(cause)
          const detail = clampFailureDetail(
            isGenericConnectionClose(message) ? summarizeProcessFailure(stderr(), message) : message
          )
          return {
            state: "error" as const,
            methods: auth.methods,
            canLogout: auth.canLogout,
            ...(detail === undefined ? {} : { detail })
          }
        }
      }),
    authenticate: (methodId) =>
      adapterPromise("authenticate", async () => {
        await connection.agent.request(acp.methods.agent.authenticate, { methodId })
      }),
    logout: adapterPromise("logout", async () => {
      if (!auth.canLogout) throw new Error("ACP agent did not advertise logout support")
      await connection.agent.request(acp.methods.agent.logout, {})
    }),
    ...(questions === undefined
      ? {}
      : {
          answerQuestion: (sessionId: string, questionId: string, answer: QuestionAnswer) =>
            adapterPromise("answerQuestion", () =>
              questions.answerQuestion(sessionId, questionId, answer)
            )
        }),
    listSessions: adapterPromise("listSessions", async () => {
      const sessions: AgentSessionSummary[] = []
      let cursor: string | undefined
      do {
        const response = await connection.agent.request(
          acp.methods.agent.session.list,
          cursor === undefined ? {} : { cursor }
        )
        sessions.push(
          ...response.sessions.map((session) => ({
            cwd: session.cwd,
            sessionId: session.sessionId,
            ...(session.title == null ? {} : { title: session.title }),
            ...(session.updatedAt == null ? {} : { updatedAt: session.updatedAt })
          }))
        )
        const next = response.nextCursor ?? undefined
        if (next === cursor) break
        cursor = next
      } while (cursor !== undefined)
      return sessions
    }),
    createSession: (cwd, toolGateway) =>
      adapterPromise("createSession", async () => {
        const response = (await connection.agent.request(acp.methods.agent.session.new, {
          cwd,
          mcpServers: mcpServers(toolGateway)
        })) as NewSessionResponse
        if (options.piStartupInfoBySession !== undefined) {
          const startupInfo = extractPiStartupInfo(response)
          if (startupInfo !== undefined) {
            options.piStartupInfoBySession.set(response.sessionId, startupInfo)
          }
        }
        const metadata = sessionMetadata(response.sessionId, response, options.harnessId)
        return (
          options.customization?.customizeSessionMetadata?.(
            response.sessionId,
            response,
            metadata
          ) ?? metadata
        )
      }),
    loadSession: (sessionId, cwd, toolGateway) =>
      adapterPromise("loadSession", async () => {
        const response = (await connection.agent.request(acp.methods.agent.session.load, {
          cwd,
          mcpServers: mcpServers(toolGateway),
          sessionId
        })) as AcpSessionMetadataResponse
        const metadata = sessionMetadata(sessionId, response, options.harnessId)
        return (
          options.customization?.customizeSessionMetadata?.(sessionId, response, metadata) ??
          metadata
        )
      }),
    prompt: (sessionId, input) =>
      adapterPromise("prompt", async () => {
        const response = await connection.agent.request(acp.methods.agent.session.prompt, {
          prompt: acpPrompt(normalizePromptInput(input), promptCapabilities),
          sessionId
        })
        const stopDetail = await options.piSessionError?.(sessionId)
        return {
          stopReason: response.stopReason,
          ...(stopDetail === undefined ? {} : { stopDetail })
        }
      }),
    cancel: (sessionId) =>
      adapterPromise("cancel", async () => {
        // Per spec, cancelling a turn resolves its pending permission
        // requests as cancelled before the agent is notified.
        questions?.cancelQuestions(sessionId)
        await connection.agent.notify(acp.methods.agent.session.cancel, { sessionId })
      }),
    setMode: (sessionId, modeId) =>
      adapterPromise("setMode", async () => {
        await connection.agent.request(acp.methods.agent.session.setMode, { modeId, sessionId })
      }),
    setConfigOption: (sessionId, configId, value) =>
      adapterPromise("setConfigOption", async () => {
        const customized = await options.customization?.setConfigOption?.({
          configId,
          connection,
          sessionId,
          value
        })
        if (customized !== undefined) return customized
        const selection = acpConfigSelection(options.harnessId, configId, value)
        const response = await connection.agent.request(acp.methods.agent.session.setConfigOption, {
          configId: selection.configId,
          sessionId,
          value: selection.value
        })
        return normalizeAcpConfigOptions(response.configOptions ?? [], options.harnessId)
      }),
    close: runtimeEffect("close", () => {
      connection.close(new Error(summarizeProcessFailure(stderr(), "agent connection closed")))
      terminate()
    })
  }
  return (
    options.customization?.extendConnection?.(base, {
      connection,
      ...(questions === undefined ? {} : { questions })
    }) ?? base
  )
}
/* v8 ignore stop */
