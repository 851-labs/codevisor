import {
  adapterPromise,
  clampFailureDetail,
  listPiAgentSessions,
  withoutEnv,
  type AgentProvider,
  type AgentSessionHandle,
  type AgentSessionSummary,
  type HarnessAccountContext,
  type HarnessDefinition,
  type ProviderEnvironment,
  type ToolGatewayConfig
} from "@codevisor/agent-runtime"
import { Effect } from "effect"

import { spawnPiClient, type PiConnector } from "./client.js"
import { gatewayExtension, writeTemporaryExtension, type ExtensionWriter } from "./gateway.js"
import { startPiSession, type PiSession } from "./session.js"

export interface PiProviderConfig {
  /// Injectable for tests: scripted Pi processes instead of a spawned binary.
  readonly connector?: PiConnector
  readonly writeExtension?: ExtensionWriter
  readonly scanAgentSessions?: (
    agentDir: string | undefined
  ) => Promise<ReadonlyArray<AgentSessionSummary>>
}

/// Pi, driven directly over its RPC mode (`pi --mode rpc`): the user's own
/// Pi, with its models, settings, extensions and sessions.
export const makePiProvider = (
  environment: ProviderEnvironment,
  config: PiProviderConfig = {}
): AgentProvider => {
  const connector = config.connector ?? spawnPiClient
  const writeExtension = config.writeExtension ?? writeTemporaryExtension
  const scanAgentSessions =
    config.scanAgentSessions ??
    ((agentDir: string | undefined) => listPiAgentSessions({ agentDir }))

  const locate = (definition: HarnessDefinition): string | undefined => {
    for (const candidate of [...definition.detectBinaries, ...(definition.fallbackPaths ?? [])]) {
      const located = environment.locateExecutable(candidate, environment.env)
      if (located !== undefined) return located
    }
    return undefined
  }

  const start = async (
    definition: HarnessDefinition,
    cwd: string,
    emit: Parameters<AgentProvider["createSession"]>[2],
    account: HarnessAccountContext | undefined,
    toolGateway: ToolGatewayConfig | undefined,
    resume?: string
  ): Promise<PiSession> => {
    const command = locate(definition)
    if (command === undefined) throw new Error("pi not found on PATH")
    const gateway =
      toolGateway === undefined
        ? undefined
        : {
            path: await writeExtension("codevisor-gateway", gatewayExtension),
            env: {
              CODEVISOR_MCP_GATEWAY_NAME: toolGateway.name,
              CODEVISOR_MCP_GATEWAY_URL: toolGateway.url,
              CODEVISOR_MCP_GATEWAY_TOKEN: toolGateway.bearerToken
            }
          }
    const client = await connector({
      command,
      args: [
        ...(gateway === undefined ? [] : ["-e", gateway.path]),
        ...(resume === undefined ? [] : ["--session", resume])
      ],
      cwd,
      env: { ...withoutEnv(environment.env, account?.unsetEnv), ...account?.env, ...gateway?.env }
    })
    return startPiSession(client, emit)
  }

  const handleFor = (session: PiSession): AgentSessionHandle => ({
    prompt: (input) => adapterPromise("prompt", () => session.prompt(input)),
    cancel: adapterPromise("cancel", async () => {
      await session.cancel()
      return { runtimeState: "reusable" as const }
    }),
    // Pi has no modes; its thinking level is a config option.
    setMode: (modeId) =>
      adapterPromise("setMode", () => Promise.reject(new Error(`Pi has no mode named ${modeId}`))),
    setConfigOption: (configId, value) =>
      adapterPromise("setConfigOption", () => session.setConfigOption(configId, value)),
    answerQuestion: (questionId, answer) =>
      adapterPromise("answerQuestion", async () => session.answerQuestion(questionId, answer)),
    close: Effect.sync(() => session.close())
  })

  const created = (session: PiSession) => ({
    handle: handleFor(session),
    metadata: { sessionId: session.key, configOptions: session.configOptions() }
  })

  return {
    id: "pi",
    readiness: (definition) =>
      locate(definition) === undefined
        ? { detail: "CLI not found on PATH", state: "unavailable" }
        : { state: "ready" },
    createSession: (definition, cwd, emit, account, toolGateway) =>
      adapterPromise("createSession", async () =>
        created(await start(definition, cwd, emit, account, toolGateway))
      ),
    loadSession: (definition, agentSessionId, cwd, emit, account, toolGateway) =>
      adapterPromise("loadSession", async () => {
        const session = await start(definition, cwd, emit, account, toolGateway, agentSessionId)
        return { ...created(session), sessionId: session.key }
      }),
    // Sessions live in the account's own agent dir when it has one.
    listAgentSessions: (_definition, account) =>
      scanAgentSessions(account?.env?.PI_CODING_AGENT_DIR),
    // Pi is signed in when it has a model to use: any provider it can reach.
    probeAuth: (definition, account) =>
      adapterPromise("probeAuth", async () => {
        const command = locate(definition)
        if (command === undefined) throw new Error("pi not found on PATH")
        const client = await connector({
          command,
          args: ["--no-session"],
          cwd: environment.env.HOME ?? process.cwd(),
          env: { ...withoutEnv(environment.env, account?.unsetEnv), ...account?.env }
        })
        try {
          const available = (await client.command("get_available_models")) as { models?: unknown }
          const signedIn = Array.isArray(available?.models) && available.models.length > 0
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
            // The client rejects with Pi's error.
            detail: clampFailureDetail((cause as Error).message) ?? "Couldn't check Pi's sign-in."
          }
        } finally {
          client.close()
        }
      })
  }
}
