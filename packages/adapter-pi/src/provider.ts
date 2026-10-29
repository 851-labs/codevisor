import {
  adapterPromise,
  clampFailureDetail,
  locateHarnessBinary,
  listPiAgentSessions,
  TRUSTED_LAUNCH,
  trustArgs,
  withoutEnv,
  type AgentProvider,
  type AgentSessionHandle,
  type AgentSessionSummary,
  type CreateSessionOptions,
  type HarnessAccountContext,
  type HarnessDefinition,
  type ProviderEnvironment,
  type ToolGatewayConfig
} from "@codevisor/agent-runtime"
import { Effect } from "effect"

import { PiExitedError, spawnPiClient, type PiConnector } from "./client.js"
import { gatewayExtension, writeTemporaryExtension, type ExtensionWriter } from "./gateway.js"
import { startPiSession, type PiSession } from "./session.js"
import { errorMessage, record } from "./values.js"

interface PiGatewayExtension {
  readonly path: string
  readonly env: Readonly<Record<string, string>>
}

export interface PiProviderConfig {
  readonly connector?: PiConnector
  readonly writeExtension?: ExtensionWriter
  readonly scanAgentSessions?: (
    agentDir: string | undefined
  ) => Promise<ReadonlyArray<AgentSessionSummary>>
}

const piSessionHandle = (session: PiSession): AgentSessionHandle => ({
  prompt: (input) => adapterPromise("prompt", () => session.prompt(input)),
  steer: (input) => adapterPromise("steer", () => session.steer(input)),
  cancel: adapterPromise("cancel", async () => {
    await session.cancel()
    return { runtimeState: "reusable" as const }
  }),
  setMode: (modeId) =>
    adapterPromise("setMode", () => Promise.reject(new Error(`Pi has no mode named ${modeId}`))),
  setConfigOption: (configId, value) =>
    adapterPromise("setConfigOption", () => session.setConfigOption(configId, value)),
  answerQuestion: (questionId, answer) =>
    adapterPromise("answerQuestion", async () => session.answerQuestion(questionId, answer)),
  replyToQuestion: (questionId, reply) =>
    adapterPromise("replyToQuestion", async () => session.replyToQuestion(questionId, reply)),
  close: Effect.sync(() => session.close())
})

const createdSession = (session: PiSession) => ({
  handle: piSessionHandle(session),
  metadata: {
    sessionId: session.key,
    configOptions: session.configOptions(),
    ...(session.skills === undefined ? {} : { skills: session.skills })
  }
})

const forkArgs = (sessionOptions: CreateSessionOptions | undefined): ReadonlyArray<string> =>
  sessionOptions?.forkFrom === undefined ? [] : ["--fork", sessionOptions.forkFrom]

export const makePiProvider = (
  environment: ProviderEnvironment,
  config: PiProviderConfig = {}
): AgentProvider => {
  const connector = config.connector ?? spawnPiClient
  const writeExtension = config.writeExtension ?? writeTemporaryExtension
  const scanAgentSessions =
    config.scanAgentSessions ??
    ((agentDir: string | undefined) => listPiAgentSessions({ agentDir }))

  const start = async (
    definition: HarnessDefinition,
    cwd: string,
    emit: Parameters<AgentProvider["createSession"]>[2],
    account: HarnessAccountContext | undefined,
    toolGateway: ToolGatewayConfig | undefined,
    sessionArgs: ReadonlyArray<string> = []
  ): Promise<PiSession> => {
    const command = locateHarnessBinary(definition, environment)
    if (command === undefined) throw new Error("pi not found on PATH")
    let gateway: PiGatewayExtension | undefined
    if (toolGateway !== undefined) {
      gateway = {
        path: await writeExtension("codevisor-gateway", gatewayExtension),
        env: {
          CODEVISOR_MCP_GATEWAY_NAME: toolGateway.name,
          CODEVISOR_MCP_GATEWAY_URL: toolGateway.url,
          CODEVISOR_MCP_GATEWAY_TOKEN: toolGateway.bearerToken
        }
      }
    }
    const env = {
      ...withoutEnv(await environment.envFor(cwd), account?.unsetEnv),
      ...account?.env,
      ...gateway?.env
    }
    const client = await connector({
      command,
      args: [
        ...(await trustArgs(environment, command, TRUSTED_LAUNCH.pi, env)),
        ...(gateway === undefined ? [] : ["-e", gateway.path]),
        ...sessionArgs
      ],
      cwd,
      env
    })
    return startPiSession(client, emit)
  }

  return {
    id: "pi",
    readiness: (definition) =>
      locateHarnessBinary(definition, environment) === undefined
        ? { detail: "CLI not found on PATH", state: "unavailable" }
        : { state: "ready" },
    createSession: (definition, cwd, emit, account, toolGateway, sessionOptions) =>
      adapterPromise("createSession", async () =>
        createdSession(
          await start(definition, cwd, emit, account, toolGateway, forkArgs(sessionOptions))
        )
      ),
    loadSession: (definition, agentSessionId, cwd, emit, account, toolGateway) =>
      adapterPromise("loadSession", async () => {
        const session = await start(definition, cwd, emit, account, toolGateway, [
          "--session",
          agentSessionId
        ])
        return { ...createdSession(session), sessionId: session.key }
      }),
    listAgentSessions: (_definition, account) =>
      scanAgentSessions(account?.env?.PI_CODING_AGENT_DIR),
    probeAuth: (definition, account) =>
      adapterPromise("probeAuth", async () => {
        const command = locateHarnessBinary(definition, environment)
        if (command === undefined) throw new Error("pi not found on PATH")
        const client = await connector({
          command,
          args: ["--no-session"],
          cwd: environment.env.HOME ?? process.cwd(),
          env: { ...withoutEnv(environment.env, account?.unsetEnv), ...account?.env }
        })
        try {
          const available = record(await client.command("get_available_models"))
          const signedIn = Array.isArray(available.models) && available.models.length > 0
          return {
            state: signedIn ? ("authenticated" as const) : ("unauthenticated" as const),
            methods: [],
            canLogout: false,
            ...(signedIn ? {} : { detail: "Sign in to a provider to use Pi." })
          }
        } catch (cause) {
          return {
            state: "error" as const,
            methods: [],
            canLogout: false,
            detail:
              clampFailureDetail(
                cause instanceof PiExitedError
                  ? `Pi couldn’t start: ${cause.message}`
                  : errorMessage(cause)
              ) ?? "Couldn't check Pi's sign-in."
          }
        } finally {
          client.close()
        }
      })
  }
}
