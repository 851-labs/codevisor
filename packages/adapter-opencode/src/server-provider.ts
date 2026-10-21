import { resolve } from "node:path"

import type {
  AgentSessionHandle,
  AgentSessionMetadata,
  AgentSessionSummary,
  HarnessAccountContext,
  RuntimeEmit,
  ToolGatewayConfig
} from "@codevisor/agent-runtime"

import { decodeModelRef, loadCatalog } from "./catalog.js"
import type { ReadText } from "./file-diffs.js"
import { record } from "./internal.js"
import { makeOpenCodeServerPool, type OpenCodeServerLease } from "./pool.js"
import { isReadable, makeMessageIds, type Readable } from "./server-prompt.js"
import { openServerSession, type OpenCodeSessionInfo } from "./server-session.js"
import { startOpenCodeServer, type OpenCodeServer, type OpenCodeServerOptions } from "./server.js"

export interface OpenCodeServerLaunch {
  readonly command: string
  readonly cwd: string
  readonly env: NodeJS.ProcessEnv
  readonly harnessName: string
  readonly emit: RuntimeEmit
  readonly account?: HarnessAccountContext
  readonly toolGateway?: ToolGatewayConfig
}

export interface OpenCodeServerSessionsDeps {
  readonly pool?: ReturnType<typeof makeOpenCodeServerPool>
  readonly start?: (options: OpenCodeServerOptions) => Promise<OpenCodeServer>
  readonly newMessageID?: () => string
  readonly readable?: Readable
  readonly readText?: ReadText
  readonly wait?: (ms: number) => Promise<void>
}

const VOLATILE_ENV = new Set(["PWD", "OLDPWD", "SHLVL", "_"])

const serverKey = (launch: Pick<OpenCodeServerLaunch, "command" | "env" | "toolGateway">) =>
  JSON.stringify([
    launch.command,
    Object.entries(launch.env)
      .filter(([name, value]) => value !== undefined && !VOLATILE_ENV.has(name))
      .toSorted(([left], [right]) => (left < right ? -1 : left > right ? 1 : 0)),
    launch.toolGateway?.url ?? null
  ])

const sessionInfo = (value: unknown): OpenCodeSessionInfo & { readonly directory?: string } => {
  const data = record(record(value)?.data)
  if (typeof data?.id !== "string") throw new Error("OpenCode returned a session without an id.")
  const model = decodeModelRef(data.model)
  const directory = record(data.location)?.directory
  return {
    id: data.id,
    ...(model === undefined ? {} : { model }),
    ...(typeof data.agent === "string" ? { agent: data.agent } : {}),
    ...(typeof directory === "string" ? { directory } : {})
  }
}

export const makeOpenCodeServerSessions = (deps: OpenCodeServerSessionsDeps = {}) => {
  const pool = deps.pool ?? makeOpenCodeServerPool()
  const start = deps.start ?? startOpenCodeServer
  const newMessageID = deps.newMessageID ?? makeMessageIds()
  const readable = deps.readable ?? isReadable

  const lease = (launch: Pick<OpenCodeServerLaunch, "command" | "env" | "toolGateway" | "cwd">) =>
    pool.acquire(serverKey(launch), () =>
      start({ command: launch.command, env: launch.env, cwd: launch.cwd })
    )

  const open = async (
    launch: OpenCodeServerLaunch,
    attach: (server: OpenCodeServer) => Promise<unknown>,
    pinModel: boolean
  ): Promise<{ readonly metadata: AgentSessionMetadata; readonly handle: AgentSessionHandle }> => {
    const held: OpenCodeServerLease = await lease(launch)
    const controller = new AbortController()
    const events = held.server.subscribe(controller.signal)[Symbol.asyncIterator]()
    try {
      const connected = await events.next()
      if (connected.done === true || record(connected.value)?.type !== "server.connected")
        throw new Error("OpenCode's event stream did not connect.")
      const info = sessionInfo(await attach(held.server))
      if (launch.toolGateway !== undefined) {
        await held.server.request(
          `/api/experimental/mcp/${encodeURIComponent(launch.toolGateway.name)}`,
          {
            method: "PUT",
            location: launch.cwd,
            body: {
              config: {
                type: "remote",
                url: launch.toolGateway.url,
                headers: { Authorization: `Bearer ${launch.toolGateway.bearerToken}` },
                oauth: false,
                codemode: false
              }
            }
          }
        )
      }
      const reloadCatalog = () => loadCatalog(held.server, launch.cwd, deps.wait)
      const catalog = await reloadCatalog()
      const pinned = pinModel && info.model === undefined
      if (pinned) {
        await held.server.request(`/api/session/${encodeURIComponent(info.id)}/model`, {
          body: { model: catalog.defaultModel }
        })
      }
      return openServerSession({
        server: held.server,
        info: pinned ? { ...info, model: catalog.defaultModel } : info,
        cwd: launch.cwd,
        events,
        abort: () => controller.abort(),
        catalog,
        reloadCatalog,
        emit: launch.emit,
        harnessName: launch.harnessName,
        ...(launch.account === undefined ? {} : { account: launch.account }),
        release: held.release,
        newMessageID,
        readable,
        ...(deps.readText === undefined ? {} : { readText: deps.readText })
      })
    } catch (cause) {
      controller.abort()
      await events.return?.().catch(() => undefined)
      held.release()
      throw cause
    }
  }

  return {
    create: (launch: OpenCodeServerLaunch) =>
      open(
        launch,
        (server) =>
          server.request("/api/session", { body: { location: { directory: launch.cwd } } }),
        true
      ),
    load: (launch: OpenCodeServerLaunch, sessionId: string) =>
      open(
        launch,
        async (server) => {
          const loaded = await server.request(`/api/session/${encodeURIComponent(sessionId)}`)
          const directory = sessionInfo(loaded).directory
          if (directory !== undefined && resolve(directory) !== resolve(launch.cwd))
            throw new Error(
              `OpenCode session ${sessionId} belongs to ${directory}, not ${launch.cwd}.`
            )
          return loaded
        },
        false
      ),
    list: async (
      launch: Pick<OpenCodeServerLaunch, "command" | "env" | "cwd">
    ): Promise<ReadonlyArray<AgentSessionSummary>> => {
      const held = await lease(launch)
      try {
        const sessions: Array<AgentSessionSummary> = []
        let cursor: string | undefined
        do {
          const query = new URLSearchParams({ order: "desc", limit: "100" })
          if (cursor !== undefined) query.set("cursor", cursor)
          const page = record(await held.server.request(`/api/session?${query}`))
          for (const value of Array.isArray(page?.data) ? page.data : []) {
            const session = record(value)
            const directory = record(session?.location)?.directory
            if (typeof session?.id !== "string" || typeof directory !== "string") continue
            const updated = record(session.time)?.updated
            sessions.push({
              sessionId: session.id,
              cwd: directory,
              ...(typeof session.title === "string" ? { title: session.title } : {}),
              ...(typeof updated === "number" ? { updatedAt: new Date(updated).toISOString() } : {})
            })
          }
          const next = record(page?.cursor)?.next
          cursor = typeof next === "string" && next !== cursor ? next : undefined
        } while (cursor !== undefined)
        return sessions
      } finally {
        held.release()
      }
    }
  }
}
