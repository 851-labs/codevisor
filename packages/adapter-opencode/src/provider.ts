import {
  makeAcpProvider,
  makeStdioAcpConnectorWithOptions,
  type AcpConnector
} from "@codevisor/adapter-acp"
import {
  adapterPromise,
  OPENCODE_INSTALL_PATH,
  withoutEnv,
  type AgentProvider,
  type HarnessAccountContext,
  type HarnessDefinition,
  type ProviderEnvironment,
  type RuntimeEmit,
  type ToolGatewayConfig
} from "@codevisor/agent-runtime"
import { Effect } from "effect"

import { makeOpenCodeLocator } from "./binary.js"
import { makeOpenCodeExtension } from "./extension.js"
import { withOpenCodePermissions } from "./permissions.js"
import { makeOpenCodeServerSessions, type OpenCodeServerSessionsDeps } from "./server-provider.js"
import { makeOpenCodeVersionProbe } from "./version.js"

const OPENCODE_NAMES = new Set(["opencode", OPENCODE_INSTALL_PATH])

export interface OpenCodeProviderConfig {
  readonly connector?: AcpConnector
  readonly locateOpenCode?: (env: NodeJS.ProcessEnv) => string | undefined
  readonly majorVersion?: (command: string) => Promise<number | undefined>
  readonly server?: OpenCodeServerSessionsDeps
}

export const makeOpenCodeProvider = (
  environment: ProviderEnvironment,
  config: OpenCodeProviderConfig = {}
): AgentProvider => {
  const {
    locateOpenCode = makeOpenCodeLocator(),
    majorVersion = makeOpenCodeVersionProbe(),
    server: serverDeps,
    ...acp
  } = config
  const connector =
    acp.connector ?? makeStdioAcpConnectorWithOptions({ extension: makeOpenCodeExtension })
  const opencode: ProviderEnvironment = {
    get env() {
      return environment.env
    },
    envFor: environment.envFor,
    executableExists: environment.executableExists,
    locateExecutable: (name, env) => {
      if (OPENCODE_NAMES.has(name)) {
        return locateOpenCode(env) ?? environment.locateExecutable(name, env)
      }
      return environment.locateExecutable(name, env)
    }
  }
  const fallback = makeAcpProvider(opencode, {
    ...acp,
    connector,
    providerId: "opencode",
    launchEnv: withOpenCodePermissions
  })
  const sessions = makeOpenCodeServerSessions(serverDeps)

  const serverCommand = async (definition: HarnessDefinition): Promise<string | undefined> => {
    if (fallback.readiness(definition).state !== "ready") return undefined
    const command = opencode.locateExecutable("opencode", opencode.env)
    if (command === undefined) return undefined
    return ((await majorVersion(command)) ?? 1) >= 2 ? command : undefined
  }

  const launchEnv = async (
    definition: HarnessDefinition,
    cwd: string,
    account: HarnessAccountContext | undefined,
    toolGateway: ToolGatewayConfig | undefined
  ) =>
    withOpenCodePermissions(
      {
        ...withoutEnv(await environment.envFor(cwd), account?.unsetEnv),
        ...(definition.launch?.kind === "executable" ? definition.launch.env : undefined),
        ...account?.env
      },
      toolGateway === undefined ? {} : { toolGateway }
    )

  const launch = async (
    command: string,
    definition: HarnessDefinition,
    cwd: string,
    emit: RuntimeEmit,
    account: HarnessAccountContext | undefined,
    toolGateway: ToolGatewayConfig | undefined
  ) => ({
    command,
    cwd,
    env: await launchEnv(definition, cwd, account, toolGateway),
    harnessName: definition.name,
    emit,
    ...(account === undefined ? {} : { account }),
    ...(toolGateway === undefined ? {} : { toolGateway })
  })

  return {
    ...fallback,
    createSession: (definition, cwd, emit, account, toolGateway, sessionOptions) =>
      Effect.flatMap(
        adapterPromise("resolveHarness", () => serverCommand(definition)),
        (command) =>
          command === undefined
            ? fallback.createSession(definition, cwd, emit, account, toolGateway, sessionOptions)
            : adapterPromise("createSession", async () =>
                sessions.create(await launch(command, definition, cwd, emit, account, toolGateway))
              )
      ),
    loadSession: (definition, agentSessionId, cwd, emit, account, toolGateway, sessionOptions) =>
      Effect.flatMap(
        adapterPromise("resolveHarness", () => serverCommand(definition)),
        (command) =>
          command === undefined
            ? fallback.loadSession(
                definition,
                agentSessionId,
                cwd,
                emit,
                account,
                toolGateway,
                sessionOptions
              )
            : adapterPromise("loadSession", async () => {
                const loaded = await sessions.load(
                  await launch(command, definition, cwd, emit, account, toolGateway),
                  agentSessionId
                )
                return { ...loaded, sessionId: loaded.metadata.sessionId }
              })
      ),
    listAgentSessions: async (definition, account, options) => {
      const command = await serverCommand(definition).catch(() => undefined)
      if (command === undefined)
        return (await fallback.listAgentSessions?.(definition, account, options)) ?? []
      const cwd = process.cwd()
      try {
        return await sessions.list({
          command,
          cwd,
          env: await launchEnv(definition, cwd, account, undefined)
        })
      } catch {
        return []
      }
    }
  }
}
