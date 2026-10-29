import { dirname } from "node:path"

import { decode, McpServer, SessionSummary } from "@codevisor/api"
import { makeMcpManager } from "@codevisor/mcp"
import { onTestFinished } from "vitest"

import { fixtureChanged } from "../changes-test-support.js"
import type { CloudInbox } from "../infra/cloud-inbox.js"
import { manualOAuthClock, sharedCoordinator } from "../infra/mcp-oauth-test-support.js"
import { mcpCredentialVault } from "../infra/shared-account-storage.js"
import { setUpWith } from "../routes/bot-test-support.js"
import type { CloudServerControl, CodevisorServerServices } from "../server-context-types.js"
import { jsonRequest, makeServices, startWithApp, waitFor } from "../test-support.js"
import { makePluginCatalog, type PluginCatalogOptions } from "./plugin-catalog.js"
import { fixtureCatalogOptions } from "./plugin-fixture-catalog.js"
import { makePluginPlatform } from "./plugin-platform.js"

export const localBaseUrl = "http://127.0.0.1:43210"

export const testEventsId = "dev.codevisor/test-events"

export type CloudReply = (method: string, path: string, body: unknown) => unknown

export const fakeCloud = (reply: CloudReply = () => ({})) => {
  const requests: Array<{
    readonly method: string
    readonly path: string
    readonly body: unknown
  }> = []
  const cloud: CloudServerControl = {
    deviceId: () => "device-1",
    state: () => "connected",
    managedBy: () => "app",
    connect: async () => "device-1",
    disconnect: async () => ({ removedFromAccount: false }),
    machineRequest: async (method, path, body) => {
      requests.push({ method, path, body })
      fixtureChanged()
      return reply(method, path, body)
    }
  }
  return { cloud, requests }
}

export interface PluginServicesOptions {
  readonly cloud?: CloudServerControl
  readonly inbox?: CloudInbox
  readonly catalog?: Omit<PluginCatalogOptions, "dev">
  readonly withoutPlatform?: boolean
}

export const pluginServices = async (options: PluginServicesOptions = {}) => {
  const { agents, services } = await makeServices("server-a")
  const dataDir = dirname(services.attachments.root)
  const clock = manualOAuthClock()
  const vault = mcpCredentialVault(dataDir, sharedCoordinator(clock).machine("server-a"), clock.now)
  const catalog = makePluginCatalog({
    dev: true,
    execPath: process.execPath,
    ...fixtureCatalogOptions(),
    ...options.catalog
  })
  const platform = makePluginPlatform({
    db: services.db,
    serverId: "server-a",
    vault,
    catalog,
    cloud: options.cloud,
    inbox: options.inbox,
    localBaseUrl
  })
  const mcp = makeMcpManager({
    db: services.db,
    dataDir,
    baseUrl: localBaseUrl,
    serverId: "server-a",
    catalog: catalog.resolver,
    accounts: platform.accountSource
  })
  onTestFinished(() => mcp.close())
  onTestFinished(mcp.subscribeServersChanged(fixtureChanged))
  platform.attachMcp(mcp)
  return {
    agents,
    clock,
    vault,
    platform,
    mcp,
    services: {
      ...services,
      mcp,
      pluginCatalog: catalog,
      ...(options.withoutPlatform === true ? {} : { pluginPlatform: platform })
    }
  }
}

export const startWithoutPlugins = async (extra: Partial<CodevisorServerServices> = {}) => {
  const { services } = await makeServices("server-a")
  const { mcp: _mcp, ...withoutMcp } = services
  return startWithApp({ ...withoutMcp, ...extra })
}

export const startPluginApp = async (options: PluginServicesOptions = {}) => {
  const started = await pluginServices(options)
  return { ...started, server: await startWithApp(started.services) }
}

export const startPluginServer = async (options: PluginServicesOptions = {}) => {
  const started = await pluginServices(options)
  const running = await setUpWith(async () => ({
    ...started,
    server: await startWithApp(started.services)
  }))
  await running.addProject("api-project", "api")
  return running
}

export type PluginServer = Awaited<ReturnType<typeof startPluginServer>>

export const post = (running: Pick<PluginServer, "server">, path: string, body: unknown = {}) =>
  jsonRequest(running.server, path, { body: JSON.stringify(body), method: "POST" })

export const createChat = async (running: PluginServer, title: string): Promise<string> =>
  decode(SessionSummary)(
    (await post(running, "/v1/sessions", { projectId: "api-project", harnessId: "codex", title }))
      .body
  ).id

export const installTestEvents = async (running: PluginServer): Promise<McpServer> => {
  const installed = decode(McpServer)(
    (await post(running, `/v1/plugins/catalog/${encodeURIComponent(testEventsId)}/install`)).body
  )
  await waitFor(async () => {
    const listed = (await running.mcp.list()).find((server) => server.id === installed.id)
    return (listed?.capabilities?.events.length ?? 0) > 0
  })
  return installed
}

export const pluginEventPrompts = (running: Pick<PluginServer, "agents">): ReadonlyArray<string> =>
  running.agents.prompts.flatMap(([, input]) =>
    typeof input === "string" && input.startsWith('<codevisor-event type="plugin.event"')
      ? [input]
      : []
  )

export const watchStreams = (
  running: Pick<PluginServer, "services">
): ReadonlyArray<string | undefined> => {
  const saved: Array<string | undefined> = []
  const save = running.services.db.savePluginEventCursor
  Object.assign(running.services.db, {
    savePluginEventCursor: (key: string, cursor: string | undefined) => {
      saved.push(cursor)
      fixtureChanged()
      return save(key, cursor)
    }
  })
  return saved
}
