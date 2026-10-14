import { realpath } from "node:fs/promises"

import {
  adapterPromise,
  clampFailureDetail,
  withoutEnv,
  type AgentProvider,
  type AgentSessionHandle,
  type AgentSessionSummary,
  type HarnessAccountContext,
  type HarnessDefinition,
  type ProviderEnvironment,
  type ToolGatewayConfig
} from "@codevisor/agent-runtime"
import { isoTimestamp, type HarnessUsageLimits } from "@codevisor/api"
import { Effect } from "effect"

import { accountInspection, readMuseAccount } from "./auth.js"
import {
  handshake,
  MuseExitedError,
  spawnMuseClient,
  type MuseClient,
  type MuseConnector
} from "./client.js"
import { record, text, type MuseSession } from "./protocol.js"
import { startMuseChat, type MuseChat } from "./session.js"

export interface MuseProviderConfig {
  readonly connector?: MuseConnector
  readonly hostDeadlineMs?: number
}

const CHAT_HOST_ARGS = ["--trust-workspace", "--disable-sandbox"]

const SESSION_PAGES = 5

const usageWindow = (value: unknown, id: string, label: string) => {
  const window = record(value)
  if (typeof window.usedPercent !== "number") return []
  const minutes =
    typeof window.windowDurationMins === "number" ? window.windowDurationMins : undefined
  return [
    {
      id,
      label: minutes === 300 ? "5-hour limit" : label,
      usedPercent: Math.max(0, Math.min(100, window.usedPercent)),
      ...(minutes === undefined ? {} : { durationMinutes: minutes }),
      ...(typeof window.resetsAtMs === "number"
        ? { resetsAt: new Date(window.resetsAtMs).toISOString() }
        : {})
    }
  ]
}

export const museUsageLimits = (response: unknown): HarnessUsageLimits => {
  const usage = record(response)
  const windows = [
    ...usageWindow(usage.window, "window", "Session limit"),
    ...usageWindow(usage.weekly, "weekly", "Weekly limit")
  ]
  return {
    fetchedAt: isoTimestamp(),
    harnessId: "muse-code",
    state: windows.length > 0 ? "available" : "unavailable",
    windows,
    ...(windows.length > 0
      ? {}
      : { detail: "Muse Code reports usage limits after its first reply." })
  }
}

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

  const locate = (definition: HarnessDefinition): string | undefined => {
    for (const candidate of [...definition.detectBinaries, ...(definition.fallbackPaths ?? [])]) {
      const located = environment.locateExecutable(candidate, environment.env)
      if (located !== undefined) return located
    }
    return undefined
  }
  const command = (definition: HarnessDefinition): string => {
    const located = locate(definition)
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
      env: { ...withoutEnv(environment.env, account?.unsetEnv), ...account?.env }
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
      locate(definition) === undefined
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
          for (const entry of Array.isArray(listed.sessions)
            ? (listed.sessions as Array<MuseSession>)
            : []) {
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
                  : (cause as Error).message
              ) ?? "Couldn't check Muse Code's sign-in."
          }
        }
      })
  }
}
