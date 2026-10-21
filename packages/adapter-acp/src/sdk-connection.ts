import * as acp from "@agentclientprotocol/sdk"
import type { NewSessionResponse } from "@agentclientprotocol/sdk"
import {
  adapterPromise,
  clampFailureDetail,
  normalizePromptInput,
  summarizeProcessFailure,
  type AgentSessionMetadata,
  type AgentSessionSummary,
  type PromptInput,
  type QuestionAnswer,
  type ToolGatewayConfig
} from "@codevisor/agent-runtime"
import { isRecord } from "@codevisor/api"
import type { SessionConfigOption } from "@codevisor/api"

import {
  normalizeAcpConfigOptions,
  sessionMetadata,
  type AcpSessionMetadataResponse
} from "./config-options.js"
import type { AcpAgentConnection } from "./connection.js"
import { isGenericConnectionClose } from "./internal.js"
import { acpPrompt, type AcpPromptCapabilities } from "./prompt.js"
import type { AcpSkillTracker } from "./skills.js"
import { usageLimitPromptStop, type AcpUsageLimitRule } from "./usage-limit-failures.js"

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
    readonly external?: boolean
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

export interface AcpSdkConnectionCustomization {
  readonly customizeSessionMetadata?: (
    sessionId: string,
    response: AcpSessionMetadataResponse,
    metadata: AgentSessionMetadata
  ) => AgentSessionMetadata
  readonly setConfigOption?: (
    context: AcpSetConfigOptionContext
  ) => Promise<ReadonlyArray<SessionConfigOption> | undefined>
  readonly isUsageLimitFailure?: AcpUsageLimitRule
  readonly extendConnection?: (
    connection: AcpAgentConnection,
    context: AcpConnectionExtensionContext
  ) => AcpAgentConnection
}

export interface AcpSdkConnectionOptions {
  readonly terminate?: () => void | Promise<void>
  readonly promptCapabilities?: AcpPromptCapabilities
  readonly steering?: boolean
  readonly questions?: AcpQuestionControls
  readonly skills?: AcpSkillTracker
  readonly auth?: AcpAuthControls
  readonly customization?: AcpSdkConnectionCustomization
}

export const STEERING_METHOD = "_session/steering"

export const advertisesSteering = (initialized: { readonly _meta?: unknown } | undefined) => {
  const meta = isRecord(initialized?._meta) ? initialized._meta : {}
  return isRecord(meta.steering) && meta.steering.supported === true
}

/* v8 ignore start */
const isAuthenticationRequired = (cause: unknown): boolean =>
  isRecord(cause) &&
  (cause.code === -32000 ||
    (typeof cause.message === "string" &&
      cause.message.toLowerCase().includes("authentication required")))

const mcpServers = (toolGateway: ToolGatewayConfig | undefined): Array<acp.McpServer> =>
  toolGateway === undefined
    ? []
    : [
        {
          type: "http",
          name: toolGateway.name,
          url: toolGateway.url,
          headers: [{ name: "Authorization", value: `Bearer ${toolGateway.bearerToken}` }]
        }
      ]

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
  const prompting = new Map<string, number>()

  const withSkills = async (
    sessionId: string,
    metadata: AgentSessionMetadata,
    timeoutMs: number | undefined
  ): Promise<AgentSessionMetadata> => {
    const skills = await options.skills?.current(sessionId, timeoutMs ?? 0)
    return skills === undefined ? metadata : { ...metadata, skills }
  }

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
          if (isAuthenticationRequired(cause)) {
            return {
              state: "unauthenticated" as const,
              methods: auth.methods,
              canLogout: auth.canLogout
            }
          }
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
    extRequest: (method, params) =>
      adapterPromise("extRequest", () => connection.agent.request(method, params)),
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
    createSession: (cwd, toolGateway, skillListTimeoutMs) =>
      adapterPromise("createSession", async () => {
        const params = { cwd, mcpServers: mcpServers(toolGateway) }
        let response: NewSessionResponse
        try {
          response = await connection.agent.request(acp.methods.agent.session.new, params)
        } catch (cause) {
          const external = auth.methods.find((method) => method.external === true)
          if (external === undefined || !isAuthenticationRequired(cause)) throw cause
          await connection.agent.request(acp.methods.agent.authenticate, { methodId: external.id })
          response = await connection.agent.request(acp.methods.agent.session.new, params)
        }
        const metadata = await withSkills(
          response.sessionId,
          sessionMetadata(response.sessionId, response),
          skillListTimeoutMs
        )
        return (
          options.customization?.customizeSessionMetadata?.(
            response.sessionId,
            response,
            metadata
          ) ?? metadata
        )
      }),
    loadSession: (sessionId, cwd, toolGateway, skillListTimeoutMs) =>
      adapterPromise("loadSession", async () => {
        const response = await connection.agent.request(acp.methods.agent.session.load, {
          cwd,
          mcpServers: mcpServers(toolGateway),
          sessionId
        })
        const metadata = await withSkills(
          sessionId,
          sessionMetadata(sessionId, response),
          skillListTimeoutMs
        )
        return (
          options.customization?.customizeSessionMetadata?.(sessionId, response, metadata) ??
          metadata
        )
      }),
    prompt: (sessionId, input) =>
      adapterPromise("prompt", async () => {
        prompting.set(sessionId, (prompting.get(sessionId) ?? 0) + 1)
        try {
          const response = await connection.agent.request(acp.methods.agent.session.prompt, {
            prompt: acpPrompt(normalizePromptInput(input), promptCapabilities),
            sessionId
          })
          return { stopReason: response.stopReason }
        } catch (cause) {
          if (isAuthenticationRequired(cause)) {
            return { stopReason: "end_turn", stopKind: "authRequired" as const }
          }
          const usageLimit = usageLimitPromptStop(cause, options.customization?.isUsageLimitFailure)
          if (usageLimit === undefined) throw cause
          return usageLimit
        } finally {
          const remaining = (prompting.get(sessionId) ?? 1) - 1
          if (remaining === 0) prompting.delete(sessionId)
          else prompting.set(sessionId, remaining)
        }
      }),
    ...(options.steering === true
      ? {
          steer: (sessionId: string, input: string | PromptInput) =>
            adapterPromise("steer", async () => {
              if (!prompting.has(sessionId)) return false
              try {
                const response = await connection.agent.request(STEERING_METHOD, {
                  sessionId,
                  prompt: acpPrompt(normalizePromptInput(input), promptCapabilities),
                  _meta: { steering: { idleBehavior: "promptRequired" } }
                })
                return (
                  isRecord(response) &&
                  (response.outcome === "injected" || response.outcome === "startedNewTurn")
                )
              } catch {
                return false
              }
            })
        }
      : {}),
    cancel: (sessionId) =>
      adapterPromise("cancel", async () => {
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
        const response = await connection.agent.request(acp.methods.agent.session.setConfigOption, {
          configId,
          sessionId,
          value
        })
        return normalizeAcpConfigOptions(response.configOptions ?? [])
      }),
    close: adapterPromise("close", async () => {
      connection.close(new Error(summarizeProcessFailure(stderr(), "agent connection closed")))
      await terminate()
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
