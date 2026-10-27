import { createHash, randomUUID } from "node:crypto"
import { createServer } from "node:http"

import type { RuntimeEventSink } from "@codevisor/agent-runtime"
import { Client } from "@modelcontextprotocol/sdk/client/index.js"
import { StreamableHTTPClientTransport } from "@modelcontextprotocol/sdk/client/streamableHttp.js"
import { Server } from "@modelcontextprotocol/sdk/server/index.js"
import { StreamableHTTPServerTransport } from "@modelcontextprotocol/sdk/server/streamableHttp.js"
import {
  CallToolResultSchema,
  type ClientCapabilities,
  ErrorCode,
  McpError,
  type RequestId,
  type ServerCapabilities,
  type Tool
} from "@modelcontextprotocol/sdk/types.js"
import { z } from "zod"

import { listen, run, testManager } from "./mcp-manager-test-support.js"
import type { PluginAccountSource } from "./mcp-plugin-accounts.js"
import { readJsonBody, sdkTransport } from "./mcp-support.js"

export interface FakeResource {
  readonly text?: string
  readonly blob?: string
  readonly mimeType?: string
}

export interface FakePluginOptions {
  readonly capabilities?: ServerCapabilities
  readonly tools?: ReadonlyArray<Tool>
  readonly skills?: ReadonlyArray<unknown>
  readonly freshSkills?: Readonly<Record<string, unknown>>
  readonly resources?: Readonly<Record<string, FakeResource>>
  readonly failing?: ReadonlySet<string>
}

export interface FakeRequest {
  readonly method: string
  readonly params: Record<string, unknown>
}

export interface FakeStream {
  readonly id: RequestId
  readonly params: Record<string, unknown>
  readonly notify: (method: string, params: Record<string, unknown>) => Promise<void>
  readonly end: (result: Record<string, unknown>) => void
  readonly cancelled: Promise<void>
  readonly responseClosed: Promise<void>
}

export interface FakePlugin {
  readonly url: string
  readonly requests: Array<FakeRequest>
  readonly notifications: Array<FakeRequest>
  readonly clientCapabilities: () => ClientCapabilities | undefined
  readonly nextStream: () => Promise<FakeStream>
  readonly resources: Map<string, FakeResource>
}

export const SUBSCRIPTION_ID = "io.modelcontextprotocol/subscriptionId"

export const pluginExtensions: ServerCapabilities = {
  tools: {},
  resources: {},
  extensions: {
    "io.modelcontextprotocol/events": { listChanged: false },
    "io.modelcontextprotocol/skills": {},
    "io.modelcontextprotocol/ui": {},
    "dev.codevisor/panes": {
      panes: [{ type: "dashboard", title: "Alerts", resourceUri: "ui://grafana/alerts.html" }]
    },
    "dev.codevisor/webhooks": {
      ingress: [{ name: "alerts", title: "Grafana alert webhook" }, { name: "raw" }]
    }
  }
}

export const eventPages: Readonly<Record<string, Record<string, unknown>>> = {
  first: {
    events: [{ name: "alert.firing", description: "An alert started firing" }],
    nextCursor: "second"
  },
  second: { events: [{ name: "alert.resolved" }] }
}

const closers: Array<() => Promise<void>> = []

export const closeFakePlugins = async (): Promise<void> => {
  await Promise.allSettled(closers.splice(0).map((close) => close()))
}

export const fileDigest = (bytes: Buffer): string =>
  `sha256:${createHash("sha256").update(bytes).digest("hex")}`

export interface SkillFixtureFile {
  readonly uri: string
  readonly digest: string
  readonly size: number
}

export interface SkillFixtureEntry {
  readonly uri: string
  readonly frontmatter: Record<string, unknown>
  readonly resources: ReadonlyArray<SkillFixtureFile>
}

export interface SkillFixture {
  readonly entry: SkillFixtureEntry
  readonly resources: Record<string, FakeResource>
}

export const skillFixture = (
  name: string,
  description: string | undefined,
  files: Readonly<Record<string, FakeResource>>
): SkillFixture => {
  const resources: Record<string, FakeResource> = {}
  const manifest = Object.entries(files).map(([path, resource]) => {
    const uri = `skill://${name}/${path}`
    resources[uri] = resource
    const bytes = resourceBytes(resource)
    return { uri, digest: fileDigest(bytes), size: bytes.length }
  })
  return {
    entry: {
      uri: `skill://${name}/SKILL.md`,
      frontmatter: { name, ...(description === undefined ? {} : { description }) },
      resources: manifest
    },
    resources
  }
}

export const startFakePlugin = async (options: FakePluginOptions = {}): Promise<FakePlugin> => {
  const requests: Array<FakeRequest> = []
  const notifications: Array<FakeRequest> = []
  const resources = new Map(Object.entries(options.resources ?? {}))
  const opened: Array<FakeStream> = []
  const waiting: Array<(stream: FakeStream) => void> = []
  const closedResponses = new Map<RequestId, Promise<void>>()
  const sdkServers: Array<Server> = []
  const openStream = (
    id: RequestId,
    params: Record<string, unknown>,
    signal: AbortSignal,
    send: (method: string, params: Record<string, unknown>) => Promise<void>
  ): Promise<Record<string, unknown>> => {
    const ended = Promise.withResolvers<Record<string, unknown>>()
    const cancelled = Promise.withResolvers<void>()
    signal.addEventListener("abort", () => cancelled.resolve())
    const stream: FakeStream = {
      id,
      params,
      notify: (method, values) => send(method, { ...values, _meta: { [SUBSCRIPTION_ID]: id } }),
      end: ended.resolve,
      cancelled: cancelled.promise,
      responseClosed: closedResponses.get(id) ?? Promise.resolve()
    }
    const waiter = waiting.shift()
    if (waiter === undefined) opened.push(stream)
    else waiter(stream)
    return ended.promise
  }

  const makeSdkServer = (): Server => {
    const sdkServer = new Server(
      { name: "fake-plugin", version: "1" },
      { capabilities: options.capabilities ?? pluginExtensions }
    )
    sdkServer.fallbackNotificationHandler = async (notification) => {
      notifications.push({ method: notification.method, params: notification.params ?? {} })
    }
    sdkServer.fallbackRequestHandler = async (request, extra) => {
      const params = request.params ?? {}
      requests.push({ method: request.method, params })
      if (options.failing?.has(request.method) === true) {
        throw new McpError(ErrorCode.InternalError, `${request.method} failed`)
      }
      const send = (method: string, values: Record<string, unknown>) =>
        extra.sendNotification({ method, params: values })
      switch (request.method) {
        case "tools/list":
          return { tools: [...(options.tools ?? [])] }
        case "tools/call":
          return { content: [{ type: "text", text: JSON.stringify(params) }] }
        case "resources/read":
          return readResource(resources, String(params.uri))
        case "events/list":
          return eventPages[typeof params.cursor === "string" ? params.cursor : "first"] ?? {}
        case "skills/list":
          return { skills: [...(options.skills ?? [])] }
        case "skills/get":
          return { skill: options.freshSkills?.[String(params.uri)] }
        case "events/stream":
          return openStream(request.id, params, extra.signal, send)
        case "test/announce":
          await extra.sendNotification(announcement(params))
          return {}
        default:
          throw new McpError(ErrorCode.MethodNotFound, `Unknown method ${request.method}`)
      }
    }

    sdkServers.push(sdkServer)
    return sdkServer
  }

  const sessions = new Map<string, StreamableHTTPServerTransport>()
  const sessionFor = async (header: string | string[] | undefined) => {
    const existing = typeof header === "string" ? sessions.get(header) : undefined
    if (existing !== undefined) return existing
    const transport = new StreamableHTTPServerTransport({
      sessionIdGenerator: randomUUID,
      onsessioninitialized: (id) => {
        sessions.set(id, transport)
      }
    })
    await makeSdkServer().connect(sdkTransport(transport))
    return transport
  }

  const httpServer = createServer(async (request, response) => {
    const body = await readJsonBody(request)
    const message = MessageSchema.safeParse(body).data ?? {}
    if (message.method === "events/stream" && message.id !== undefined) {
      const closed = Promise.withResolvers<void>()
      response.on("close", () => closed.resolve())
      closedResponses.set(message.id, closed.promise)
    }
    const transport = await sessionFor(request.headers["mcp-session-id"])
    await transport.handleRequest(request, response, body)
  })
  const base = await listen(httpServer)
  closers.push(async () => {
    httpServer.closeAllConnections()
    await Promise.allSettled(sdkServers.map((server) => server.close()))
  })

  return {
    url: `${base}/mcp`,
    requests,
    notifications,
    clientCapabilities: () => sdkServers.at(-1)?.getClientCapabilities(),
    nextStream: () => {
      const ready = opened.shift()
      if (ready !== undefined) return Promise.resolve(ready)
      return new Promise((resolve) => waiting.push(resolve))
    },
    resources
  }
}

const MessageSchema = z.object({
  id: z.union([z.string(), z.number()]).optional(),
  method: z.string().optional()
})

const AnnouncementSchema = z.object({
  method: z.string(),
  values: z.record(z.string(), z.unknown()).optional()
})

const announcement = (params: Record<string, unknown>) => {
  const { method, values } = AnnouncementSchema.parse(params)
  return { method, ...(values === undefined ? {} : { params: values }) }
}

const resourceBytes = (resource: FakeResource): Buffer => {
  if (resource.text !== undefined) return Buffer.from(resource.text, "utf8")
  return Buffer.from(resource.blob ?? "", "base64")
}

const readResource = (resources: Map<string, FakeResource>, uri: string) => {
  const resource = resources.get(uri)
  if (resource === undefined) throw new McpError(ErrorCode.InvalidParams, `Unknown ${uri}`)
  return {
    contents: [
      {
        uri,
        ...(resource.mimeType === undefined ? {} : { mimeType: resource.mimeType }),
        ...(resource.text === undefined ? { blob: resource.blob ?? "" } : { text: resource.text })
      }
    ]
  }
}

export const pluginGatewaySession = async (
  options: FakePluginOptions,
  accounts?: PluginAccountSource,
  sink?: RuntimeEventSink
) => {
  const plugin = await startFakePlugin(options)
  const { db, manager } = await testManager(accounts === undefined ? {} : { accounts })
  manager.setBaseUrl(await listen(createServer(manager.handleGatewayRequest)))
  const server = await manager.create({
    authType: "none",
    enabled: true,
    name: "Grafana",
    transport: "http",
    url: plugin.url
  })
  const project = await run(db.createProject({ folderPath: "/tmp/mcp-plugin-gateway" }))
  const session = await run(
    db.createSession({ harnessId: "codex", projectId: project.id, title: "Plugins" })
  )
  const issued = await manager.issueGateway(session.id, project.id, sink)
  const client = new Client({ name: "plugin-gateway-test", version: "1" })
  await client.connect(
    sdkTransport(
      new StreamableHTTPClientTransport(new URL(issued.url), {
        requestInit: { headers: { authorization: `Bearer ${issued.bearerToken}` } }
      })
    )
  )
  const call = async (name: string, args: Record<string, unknown>) => {
    const result = CallToolResultSchema.parse(await client.callTool({ name, arguments: args }))
    const block = result.content.find((entry) => entry.type === "text")
    return { isError: result.isError === true, text: block?.type === "text" ? block.text : "" }
  }
  const execute = async (code: string) =>
    client.callTool({ name: "execute", arguments: { description: "Run test code", code } })
  return { call, client, db, execute, manager, plugin, project, server, session }
}
