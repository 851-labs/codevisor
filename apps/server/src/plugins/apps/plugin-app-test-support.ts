import { readFileSync } from "node:fs"
import { createServer } from "node:http"

import { Schema } from "effect"
import { onTestFinished } from "vitest"

import { readJson } from "../../server-context.js"

export interface AppPluginRequest {
  readonly method: string
  readonly params: Record<string, unknown>
}

export const alertsHtml =
  '<!doctype html><html><head><title>Alerts</title></head><body><script>parent.postMessage({jsonrpc:"2.0",id:1,method:"ui/initialize",params:{}},"*")</script></body></html>'

export const boardHtml = "<html><body>Board</body></html>"

const resources: Readonly<Record<string, Record<string, unknown>>> = {
  "ui://grafana/alerts.html": {
    mimeType: "text/html;profile=mcp-app",
    text: alertsHtml,
    _meta: {
      ui: {
        csp: {
          connectDomains: ["https://grafana.example", "javascript:alert(1)"],
          resourceDomains: ["https://cdn.example"]
        },
        permissions: { clipboardWrite: {}, camera: {} }
      }
    }
  },
  "ui://grafana/board.html": {
    mimeType: "text/html;profile=mcp-app",
    blob: Buffer.from(boardHtml).toString("base64")
  },
  "ui://grafana/data.json": { mimeType: "application/json", text: "{}" }
}

const tools = [
  {
    name: "show_alerts",
    inputSchema: { type: "object", properties: { range: { type: "string" } } },
    _meta: { ui: { resourceUri: "ui://grafana/alerts.html" } }
  },
  { name: "refresh", inputSchema: { type: "object" }, _meta: { ui: { visibility: ["app"] } } },
  { name: "summarize", inputSchema: { type: "object" }, _meta: { ui: { visibility: ["model"] } } }
]

const capabilities = {
  tools: {},
  resources: {},
  extensions: {
    "dev.codevisor/panes": {
      panes: [
        { type: "dashboard", title: "Dashboard", resourceUri: "ui://grafana/board.html" },
        { type: "broken", title: "Broken", resourceUri: "ui://grafana/data.json" }
      ]
    }
  }
}

const ListeningAddress = Schema.Struct({ port: Schema.Number })

const RpcMessage = Schema.Struct({
  id: Schema.optional(Schema.Union([Schema.String, Schema.Number])),
  method: Schema.String,
  params: Schema.optional(Schema.Record(Schema.String, Schema.Unknown))
})

const rpcReply = (
  message: typeof RpcMessage.Type,
  definition: AppPluginDefinition,
  answer: (method: string, params: Record<string, unknown>) => unknown
) => {
  if (message.method === "initialize") {
    return {
      jsonrpc: "2.0",
      id: message.id,
      result: {
        protocolVersion: "2025-06-18",
        capabilities: definition.capabilities,
        serverInfo: { name: "app-plugin", version: "1" }
      }
    }
  }
  try {
    return { jsonrpc: "2.0", id: message.id, result: answer(message.method, message.params ?? {}) }
  } catch (cause) {
    return { jsonrpc: "2.0", id: message.id, error: { code: -32602, message: String(cause) } }
  }
}

export interface AppPluginDefinition {
  readonly capabilities: Record<string, unknown>
  readonly tools: ReadonlyArray<Record<string, unknown>>
  readonly resources: Readonly<Record<string, Record<string, unknown>>>
  readonly results: Readonly<Record<string, Record<string, unknown>>>
}

export const grafanaPlugin: AppPluginDefinition = { capabilities, tools, resources, results: {} }

export const zillowPlugin = (): AppPluginDefinition =>
  Schema.decodeUnknownSync(RecordedPlugin)(
    JSON.parse(readFileSync(new URL("./zillow-fixture.json", import.meta.url), "utf8"))
  )

const RecordedPlugin = Schema.Struct({
  capabilities: Schema.Record(Schema.String, Schema.Unknown),
  tools: Schema.Array(Schema.Record(Schema.String, Schema.Unknown)),
  resources: Schema.Record(Schema.String, Schema.Record(Schema.String, Schema.Unknown)),
  results: Schema.Record(Schema.String, Schema.Record(Schema.String, Schema.Unknown))
})

export const startAppPlugin = async (definition: AppPluginDefinition = grafanaPlugin) => {
  const requests: Array<AppPluginRequest> = []

  const answer = (method: string, params: Record<string, unknown>) => {
    requests.push({ method, params })
    if (method === "tools/list") return { tools: definition.tools }
    if (method === "tools/call") {
      return (
        definition.results[String(params.name)] ?? {
          content: [{ type: "text", text: "done" }],
          structuredContent: { params }
        }
      )
    }
    const resource = definition.resources[String(params.uri)]
    if (method !== "resources/read" || resource === undefined) throw new Error(`Unknown ${method}`)
    return { contents: [{ uri: params.uri, ...resource }] }
  }

  const httpServer = createServer(async (request, response) => {
    const message = Schema.decodeUnknownSync(RpcMessage)(await readJson(request))
    if (message.id === undefined) {
      response.writeHead(202).end()
      return
    }
    response.writeHead(200, { "content-type": "application/json" })
    response.end(JSON.stringify(rpcReply(message, definition, answer)))
  })
  await new Promise<void>((resolve) => httpServer.listen(0, "127.0.0.1", resolve))
  onTestFinished(() => new Promise<void>((resolve) => httpServer.close(() => resolve())))
  const { port } = Schema.decodeUnknownSync(ListeningAddress)(httpServer.address())
  return { requests, url: `http://127.0.0.1:${port}/mcp` }
}
