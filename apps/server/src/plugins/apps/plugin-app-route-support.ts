import { mkdtempSync } from "node:fs"
import { createServer, type IncomingHttpHeaders } from "node:http"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { buffer } from "node:stream/consumers"

import type { RuntimeEvent } from "@codevisor/agent-runtime"
import { Client as McpClient } from "@modelcontextprotocol/sdk/client/index.js"
import { Schema } from "effect"
import { expect, onTestFinished } from "vitest"

import { gatewayTransport } from "../../routes/gateway-test-support.js"
import { jsonRequest, run, start, tempDirs } from "../../test-support.js"
import { grafanaPlugin, startAppPlugin } from "./plugin-app-test-support.js"

export const Launch = Schema.Struct({ url: Schema.String, expiresAt: Schema.String })

const ExecutionApps = Schema.Struct({
  execution: Schema.Struct({
    apps: Schema.Array(Schema.Struct({ viewId: Schema.String }))
  })
})

export const Boot = Schema.Struct({
  html: Schema.String,
  allow: Schema.String,
  hostContext: Schema.Record(Schema.String, Schema.Unknown),
  hostCapabilities: Schema.Record(Schema.String, Schema.Unknown),
  toolInput: Schema.optional(Schema.Record(Schema.String, Schema.Unknown)),
  toolResult: Schema.optional(Schema.Unknown),
  endpoints: Schema.Struct({
    toolsCall: Schema.String,
    resourcesRead: Schema.String,
    modelContext: Schema.String
  })
})

export const secured = async (definition = grafanaPlugin, name = "Grafana") => {
  const plugin = await startAppPlugin(definition)
  const { agents, server, services } = await start({
    allowLocalhostWithoutAuth: false,
    requireBearerToken: true
  })
  const token = await run(services.db.getOrCreateConnectionToken)
  const authorized = { authorization: `Bearer ${token}` }
  const created = await jsonRequest(server, "/v1/mcps", {
    method: "POST",
    headers: authorized,
    body: JSON.stringify({
      name,
      transport: "http",
      url: plugin.url,
      authType: "none",
      enabled: true
    })
  })
  const serverId = Schema.decodeUnknownSync(Schema.Struct({ id: Schema.String }))(created.body).id
  return { agents, authorized, plugin, server, serverId, services }
}

export type Secured = Awaited<ReturnType<typeof secured>>

export const capturedView = async (
  { services, serverId }: Secured,
  toolName = "show_alerts",
  args = '{ range: "1h" }'
): Promise<string> => {
  const folderPath = mkdtempSync(join(tmpdir(), "codevisor-plugin-apps-"))
  tempDirs.push(folderPath)
  const project = await run(services.db.createProject({ folderPath }))
  const session = await run(
    services.db.createSession({ harnessId: "codex", projectId: project.id, title: "Apps" })
  )
  const events: Array<RuntimeEvent> = []
  const gateway = await services.mcp.issueGateway(session.id, project.id, (event) => {
    events.push(event)
  })
  const client = new McpClient({ name: "plugin-app-routes", version: "1" })
  await client.connect(gatewayTransport(gateway))
  onTestFinished(() => client.close())
  const path = JSON.stringify(`${serverId}.${toolName}`)
  await client.callTool({
    name: "execute",
    arguments: {
      description: "Show the alerts",
      code: `async () => machines.current.tools[${path}](${args})`
    }
  })
  const finished = Schema.decodeUnknownSync(ExecutionApps)(events.at(-1)?.payload)
  return finished.execution.apps[0]!.viewId
}

export const launch = async (setup: Secured, path: string): Promise<string> => {
  const response = await jsonRequest(setup.server, path, {
    method: "POST",
    headers: setup.authorized
  })
  expect(response.status).toBe(200)
  return Schema.decodeUnknownSync(Launch)(response.body).url
}

export const shell = async (setup: Secured, url: string) => {
  const response = await fetch(`${setup.server.url}${url}`)
  const html = await response.text()
  const script = /const boot = (.*);\n/.exec(html)
  return {
    status: response.status,
    policy: response.headers.get("content-security-policy"),
    html,
    boot: script === null ? undefined : Schema.decodeUnknownSync(Boot)(JSON.parse(script[1]!))
  }
}

const ListedTools = Schema.Array(
  Schema.Struct({
    name: Schema.String,
    capabilities: Schema.optional(
      Schema.Struct({
        tools: Schema.Array(
          Schema.Struct({ name: Schema.String, app: Schema.optional(Schema.Boolean) })
        )
      })
    )
  })
)

export const appTools = (body: unknown, pluginName: string) =>
  Schema.decodeUnknownSync(ListedTools)(body)
    .find((server) => server.name === pluginName)
    ?.capabilities?.tools.map(({ name, app }) => ({ name, ...(app === undefined ? {} : { app }) }))

export const post = async (setup: Secured, url: string, body: unknown) =>
  jsonRequest(setup.server, url, { method: "POST", body: JSON.stringify(body) })

export interface RelayedRequest {
  readonly path: string
  readonly cookie: boolean
}

export const startRelay = async (target: string) => {
  const requests: Array<RelayedRequest> = []
  const relay = createServer(async (request, response) => {
    requests.push({ path: String(request.url), cookie: request.headers.cookie !== undefined })
    const body = await buffer(request)
    const upstream = await fetch(`${target}${String(request.url)}`, {
      method: String(request.method),
      headers: forwardedHeaders(request.headers),
      body: body.length === 0 ? null : body
    })
    response.writeHead(upstream.status, relayedHeaders(upstream.headers))
    response.end(Buffer.from(await upstream.arrayBuffer()))
  })
  await new Promise<void>((resolve) => relay.listen(0, "127.0.0.1", resolve))
  onTestFinished(() => new Promise<void>((resolve) => relay.close(() => resolve())))
  const { port } = Schema.decodeUnknownSync(Schema.Struct({ port: Schema.Number }))(relay.address())
  return { requests, url: `http://127.0.0.1:${port}` }
}

const droppedRequestHeaders = new Set(["host", "cookie", "connection", "content-length"])

const droppedResponseHeaders = new Set([
  "set-cookie",
  "connection",
  "content-length",
  "content-encoding",
  "transfer-encoding",
  "keep-alive"
])

const forwardedHeaders = (headers: IncomingHttpHeaders): Headers =>
  new Headers(
    Object.entries(headers)
      .filter(([name]) => !droppedRequestHeaders.has(name))
      .map(([name, value]): [string, string] => [name, String(value)])
  )

const relayedHeaders = (headers: Headers): Record<string, string> =>
  Object.fromEntries([...headers].filter(([name]) => !droppedResponseHeaders.has(name)))
