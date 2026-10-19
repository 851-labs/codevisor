import { realpath } from "node:fs/promises"

import {
  adapterPromise,
  clampFailureDetail,
  locateHarnessBinary,
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

import { accountInspection, readMuseAccount } from "./auth.js"
import {
  handshake,
  MuseExitedError,
  spawnMuseClient,
  type MuseClient,
  type MuseConnector
} from "./client.js"
import { messageOf, record, text } from "./protocol.js"
import { startMuseChat, type MuseChat } from "./session.js"
import { museUsageLimits } from "./usage.js"
import { museSessions } from "./wire.js"

export interface MuseProviderConfig {
  readonly connector?: MuseConnector
  readonly hostDeadlineMs?: number
}

const CHAT_HOST_ARGS = ["--trust-workspace", "--disable-sandbox"]

const SESSION_PAGES = 5

const museSessionHandle = (chat: MuseChat): AgentSessionHandle => ({
  prompt: (input) => adapterPromise("prompt", () => chat.prompt(input)),
  cancel: adapterPromise("cancel", async () => {
    await chat.cancel()
    return { runtimeState: "reusable" as const }
  }),
  setMode: (modeId) =>
    adapterPromise("setMode", () =>
      Promise.reject(new Error(`Muse Code has no mode named ${modeId}`))
    ),
  setConfigOption: (configId, value) =>
    adapterPromise("setConfigOption", () => chat.setConfigOption(configId, value)),
  answerQuestion: (questionId, answer) =>
    adapterPromise("answerQuestion", () => chat.answerQuestion(questionId, answer)),
  close: Effect.sync(() => chat.close())
})

const createdSession = (chat: MuseChat) => ({
  handle: museSessionHandle(chat),
  metadata: {
    sessionId: chat.key,
    configOptions: chat.configOptions(),
    ...(chat.skills === undefined ? {} : { skills: chat.skills })
  }
})

export const makeMuseProvider = (
  environment: ProviderEnvironment,
  config: MuseProviderConfig = {}
): AgentProvider => {
  const connector = config.connector ?? spawnMuseClient
  const hostDeadlineMs = config.hostDeadlineMs ?? 30_000

  const command = (definition: HarnessDefinition): string => {
    const located = locateHarnessBinary(definition, environment)
    if (located === undefined) throw new Error("muse not found on PATH")
    return located
  }

  const start = async (
    definition: HarnessDefinition,
    cwd: string,
    emit: Parameters<AgentProvider["createSession"]>[2],
    account: HarnessAccountContext | undefined,
    toolGateway: ToolGatewayConfig | undefined,
    resume?: string
  ): Promise<MuseChat> => {
    const root = await realpath(cwd).catch(() => cwd)
    const client = await connector({
      command: command(definition),
      args: CHAT_HOST_ARGS,
      cwd: root,
      env: {
        ...withoutEnv(await environment.envFor(root), account?.unsetEnv),
        ...account?.env
      }
    })
    try {
      await handshake(client)
      return await startMuseChat(client, emit, {
        cwd: root,
        ...(resume === undefined ? {} : { resume }),
        ...(toolGateway === undefined ? {} : { toolGateway })
      })
    } catch (cause) {
      client.close()
      throw cause
    }
  }

  const withHost = async <A>(
    definition: HarnessDefinition,
    account: HarnessAccountContext | undefined,
    use: (client: MuseClient) => Promise<A>
  ): Promise<A> => {
    const client = await connector({
      command: command(definition),
      args: ["--no-session-log"],
      cwd: environment.env.HOME ?? process.cwd(),
      env: { ...withoutEnv(environment.env, account?.unsetEnv), ...account?.env }
    })
    let timer: ReturnType<typeof setTimeout> | undefined
    const expired = new Promise<never>((_, reject) => {
      timer = setTimeout(
        () => reject(new Error("Muse Code didn't respond in time.")),
        hostDeadlineMs
      )
    })
    try {
      return await Promise.race([handshake(client).then(() => use(client)), expired])
    } finally {
      clearTimeout(timer)
      client.close()
    }
  }

  return {
    id: "muse",
    readiness: (definition) =>
      locateHarnessBinary(definition, environment) === undefined
        ? { detail: "CLI not found on PATH", state: "unavailable" }
        : { state: "ready" },
    createSession: (definition, cwd, emit, account, toolGateway) =>
      adapterPromise("createSession", async () =>
        createdSession(await start(definition, cwd, emit, account, toolGateway))
      ),
    loadSession: (definition, agentSessionId, cwd, emit, account, toolGateway) =>
      adapterPromise("loadSession", async () => {
        const chat = await start(definition, cwd, emit, account, toolGateway, agentSessionId)
        return { ...createdSession(chat), sessionId: chat.key }
      }),
    listAgentSessions: (definition, account) =>
      withHost(definition, account, async (client) => {
        const sessions: Array<AgentSessionSummary> = []
        let cursor: string | undefined
        for (let page = 0; page < SESSION_PAGES; page += 1) {
          const listed = record(
            await client.request("session/list", {
              limit: 200,
              ...(cursor === undefined ? {} : { cursor })
            })
          )
          for (const entry of museSessions(listed.sessions)) {
            if ((entry.kind ?? "root") !== "root" || entry.workspaceRoot === null) continue
            const title = text(entry.name) ?? text(entry.title) ?? text(entry.firstUserPrompt)
            sessions.push({
              sessionId: entry.sessionId,
              cwd: entry.workspaceRoot,
              updatedAt: entry.updatedAt,
              ...(title === undefined ? {} : { title })
            })
          }
          cursor = text(listed.nextCursor)
          if (cursor === undefined) break
        }
        return sessions
      }),
    readUsageLimits: (definition, _cwd, account) =>
      adapterPromise("readUsageLimits", () =>
        withHost(definition, account, async (client) =>
          museUsageLimits(await client.request("usage/read", {}))
        )
      ),
    probeAuth: (definition, account) =>
      adapterPromise("probeAuth", async () => {
        try {
          return await withHost(definition, account, async (client) =>
            accountInspection(await readMuseAccount(client))
          )
        } catch (cause) {
          return {
            state: "error" as const,
            methods: [],
            canLogout: false,
            detail:
              clampFailureDetail(
                cause instanceof MuseExitedError
                  ? `Muse Code couldn’t start: ${cause.message}`
                  : messageOf(cause)
              ) ?? "Couldn't check Muse Code's sign-in."
          }
        }
      })
  }
}
