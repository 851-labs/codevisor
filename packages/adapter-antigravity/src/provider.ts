import { tmpdir } from "node:os"
import { join } from "node:path"

import {
  adapterPromise,
  clampFailureDetail,
  locateHarnessBinary,
  withoutEnv,
  type AgentProvider,
  type AgentSessionHandle,
  type HarnessAccountContext,
  type HarnessDefinition,
  type ProviderEnvironment,
  type ToolGatewayConfig
} from "@codevisor/agent-runtime"
import { Effect } from "effect"

import { agyAccountLaunch, agyAuthInspection } from "./auth.js"
import { runAgy, spawnAgyProcess, type AgyConnector, type AgyRunner } from "./client.js"
import { prepareGateway } from "./gateway.js"
import { parseModels, type AgyModel } from "./models.js"
import {
  messageOf,
  MINIMUM_AGY_VERSION,
  signedOut,
  SIGN_IN_DETAIL,
  versionAtLeast
} from "./protocol.js"
import { startAgyChat, type AgyChat } from "./session.js"
import {
  agySessionSummaries,
  readSummaries,
  summariesPath,
  type SummaryReader
} from "./sessions.js"
import { agyUsageLimitsFrom } from "./usage.js"

const catalogKey = (account: HarnessAccountContext | undefined) => account?.id ?? ""

export interface AntigravityProviderConfig {
  readonly connector?: AgyConnector
  readonly runner?: AgyRunner
  readonly readSummaries?: SummaryReader
  readonly now?: () => number
  readonly catalogTtlMs?: number
  readonly commandDeadlineMs?: number
  readonly usageDeadlineMs?: number
  readonly node?: string
  readonly overlays?: string
}

const antigravitySessionHandle = (chat: AgyChat): AgentSessionHandle => ({
  prompt: (input) => adapterPromise("prompt", () => chat.prompt(input)),
  cancel: adapterPromise("cancel", async () => {
    await chat.cancel()
    return { runtimeState: "reusable" as const }
  }),
  setMode: (modeId) =>
    adapterPromise("setMode", () =>
      Promise.reject(new Error(`Antigravity has no mode named ${modeId}`))
    ),
  setConfigOption: (configId, value) =>
    adapterPromise("setConfigOption", () => chat.setConfigOption(configId, value)),
  close: Effect.sync(() => chat.close())
})

const createdSession = (chat: AgyChat) => ({
  handle: antigravitySessionHandle(chat),
  metadata: { sessionId: chat.key, configOptions: chat.configOptions() }
})

export const makeAntigravityProvider = (
  environment: ProviderEnvironment,
  config: AntigravityProviderConfig = {}
): AgentProvider => {
  const connector = config.connector ?? spawnAgyProcess
  const runner = config.runner ?? runAgy
  const reader = config.readSummaries ?? readSummaries
  const now = config.now ?? Date.now
  const catalogTtlMs = config.catalogTtlMs ?? 60 * 60_000
  const commandDeadlineMs = config.commandDeadlineMs ?? 30_000
  const usageDeadlineMs = config.usageDeadlineMs ?? 15_000
  const node = config.node ?? process.execPath
  const overlays = config.overlays ?? join(tmpdir(), "codevisor-antigravity")
  const catalogs = new Map<string, { at: number; models: ReadonlyArray<AgyModel> }>()
  const checkedVersions = new Map<string, Promise<void>>()

  const command = (definition: HarnessDefinition): string => {
    const located = locateHarnessBinary(definition, environment)
    if (located === undefined) throw new Error("agy not found on PATH")
    return located
  }
  const launchFor = (
    account: HarnessAccountContext | undefined,
    env: NodeJS.ProcessEnv = environment.env
  ) => agyAccountLaunch({ ...withoutEnv(env, account?.unsetEnv), ...account?.env })
  const home = () => environment.env.HOME ?? process.cwd()

  const run = (
    definition: HarnessDefinition,
    account: HarnessAccountContext | undefined,
    args: ReadonlyArray<string>
  ) => {
    const launch = launchFor(account)
    return runner({
      command: command(definition),
      args: [...launch.args, ...args],
      cwd: home(),
      env: launch.env,
      timeoutMs: commandDeadlineMs
    })
  }

  const checkVersion = (definition: HarnessDefinition): Promise<void> => {
    const path = command(definition)
    let checked = checkedVersions.get(path)
    if (checked === undefined) {
      checked = run(definition, undefined, ["--version"]).then((result) => {
        const version = result.stdout.trim()
        if (!versionAtLeast(version, MINIMUM_AGY_VERSION))
          throw new Error(
            `This version of Antigravity CLI (${version || "unknown"}) is too old for Codevisor. Update it to ${MINIMUM_AGY_VERSION} or newer.`
          )
      })
      checked.catch(() => checkedVersions.delete(path))
      checkedVersions.set(path, checked)
    }
    return checked
  }

  const remember = (account: HarnessAccountContext | undefined, stdout: string) => {
    const models = parseModels(stdout)
    if (models.length > 0) catalogs.set(catalogKey(account), { at: now(), models })
    return models
  }

  const catalog = async (
    definition: HarnessDefinition,
    account: HarnessAccountContext | undefined
  ): Promise<ReadonlyArray<AgyModel>> => {
    const cached = catalogs.get(catalogKey(account))
    if (cached !== undefined && now() - cached.at < catalogTtlMs) return cached.models
    const result = await run(definition, account, ["models"]).catch(() => undefined)
    if (result === undefined) return cached?.models ?? []
    if (result.code === 0) return remember(account, result.stdout)
    if (signedOut(result.stderr)) throw new Error(SIGN_IN_DETAIL)
    return cached?.models ?? []
  }

  const start = async (
    definition: HarnessDefinition,
    cwd: string,
    emit: Parameters<AgentProvider["createSession"]>[2],
    account: HarnessAccountContext | undefined,
    toolGateway: ToolGatewayConfig | undefined,
    resume?: string
  ): Promise<AgyChat> => {
    await checkVersion(definition)
    const launch = launchFor(account, await environment.envFor(cwd))
    const gateway =
      toolGateway === undefined
        ? { args: [], env: {} }
        : await prepareGateway({
            gateway: toolGateway,
            geminiDir: launch.geminiDir,
            home: home(),
            overlays,
            node
          })
    return startAgyChat(emit, {
      connector,
      command: command(definition),
      cwd,
      env: { ...launch.env, ...gateway.env },
      extraArgs: [...launch.args, ...gateway.args],
      models: await catalog(definition, account),
      ...(resume === undefined ? {} : { resume })
    })
  }

  return {
    id: "antigravity",
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
    listAgentSessions: async (_definition, account) => {
      const root = launchFor(account).geminiDir ?? join(home(), ".gemini")
      return agySessionSummaries(await reader(summariesPath(root)))
    },
    readUsageLimits: (definition, _cwd, account) =>
      adapterPromise("readUsageLimits", async () => {
        const launch = launchFor(account)
        try {
          const result = await runner({
            command: command(definition),
            args: [...launch.args, "-p", "/usage"],
            cwd: home(),
            env: launch.env,
            timeoutMs: usageDeadlineMs
          })
          return agyUsageLimitsFrom(result.code === 0 ? result.stdout : "")
        } catch {
          return agyUsageLimitsFrom("")
        }
      }),
    probeAuth: (definition, account) =>
      adapterPromise("probeAuth", async () => {
        try {
          const result = await run(definition, account, ["models"])
          if (result.code === 0) remember(account, result.stdout)
          return agyAuthInspection(result)
        } catch (cause) {
          return {
            state: "error" as const,
            methods: [],
            canLogout: false,
            detail: clampFailureDetail(messageOf(cause)) ?? "Couldn't check Antigravity's sign-in."
          }
        }
      })
  }
}
