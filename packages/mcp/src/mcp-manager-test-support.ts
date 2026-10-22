import { mkdtempSync, rmSync } from "node:fs"
import { createServer } from "node:http"
import type { Server } from "node:http"
import { tmpdir } from "node:os"
import { join } from "node:path"

import type { RuntimeEvent } from "@codevisor/agent-runtime"
import { makeDatabase } from "@codevisor/db"
import type { CodevisorDatabaseService } from "@codevisor/db"
import { CallToolResultSchema } from "@modelcontextprotocol/sdk/types.js"
import { Effect } from "effect"
import { vi } from "vitest"
import { z } from "zod"

import type { McpManager } from "./mcp-manager-types.js"
import { makeMcpManager } from "./mcp-manager.js"
import { readJsonBody } from "./mcp-support.js"

export const run = <A, E>(effect: Effect.Effect<A, E>): Promise<A> => Effect.runPromise(effect)

export const TEST_BASE_URL = "http://127.0.0.1:43210"
export const directories: string[] = []
export const databases: CodevisorDatabaseService[] = []
export const managers: McpManager[] = []
export const servers: Server[] = []

export const cleanupMcpManagerTests = async (): Promise<void> => {
  vi.restoreAllMocks()
  vi.unstubAllGlobals()
  vi.unstubAllEnvs()
  const outcomes = await Promise.allSettled(
    managers.splice(0).map(async (manager) => manager.close())
  )
  outcomes.push(
    ...(await Promise.allSettled(databases.splice(0).map(async (database) => run(database.close))))
  )
  outcomes.push(
    ...(await Promise.allSettled(
      servers
        .splice(0)
        .map(
          (server) =>
            new Promise<void>((resolve, reject) =>
              server.close((error) => (error === undefined ? resolve() : reject(error)))
            )
        )
    ))
  )
  const failures: Array<unknown> = []
  for (const outcome of outcomes) {
    if (outcome.status === "rejected") failures.push(outcome.reason)
  }
  for (const directory of directories.splice(0)) {
    try {
      rmSync(directory, { force: true, recursive: true })
    } catch (cause) {
      failures.push(cause)
    }
  }
  if (failures.length > 0) {
    throw new AggregateError(failures, "MCP manager fixture cleanup failed")
  }
}

export const listen = async (server: Server): Promise<string> => {
  servers.push(server)
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve))
  const address = server.address()
  if (address === null || typeof address === "string") throw new Error("Missing test port")
  return `http://127.0.0.1:${address.port}`
}

export const testManager = async (
  extraConfig: Partial<Parameters<typeof makeMcpManager>[0]> = {}
): Promise<{ db: CodevisorDatabaseService; manager: McpManager; directory: string }> => {
  const directory = mkdtempSync(join(tmpdir(), "codevisor-mcp-manager-"))
  directories.push(directory)
  const db = await run(
    makeDatabase({ filename: join(directory, "codevisor.sqlite"), serverId: "test" })
  )
  databases.push(db)
  const manager = makeMcpManager({
    db,
    dataDir: directory,
    baseUrl: TEST_BASE_URL,
    ...extraConfig
  })
  managers.push(manager)
  return { db, manager, directory }
}

const UpstreamRequestSchema = z.object({
  id: z.union([z.string(), z.number()]).optional(),
  method: z.string(),
  params: z.record(z.string(), z.unknown()).optional()
})

const UpstreamToolCallSchema = z.looseObject({
  name: z.string(),
  arguments: z.record(z.string(), z.unknown()).exactOptional()
})

export const workingUpstream = async () => {
  const requests: Array<{
    headers: Record<string, string | string[] | undefined>
    method: string
  }> = []
  const calls: Array<{ name: string; arguments?: Record<string, unknown> }> = []
  const server = createServer(async (request, response) => {
    const message = UpstreamRequestSchema.parse(await readJsonBody(request))
    requests.push({ headers: request.headers, method: message.method })
    if (message.method === "notifications/initialized") {
      response.writeHead(202)
      response.end()
      return
    }
    let result: unknown
    if (message.method === "initialize") {
      result = {
        protocolVersion: "2025-11-25",
        capabilities: { tools: {} },
        serverInfo: {
          name: "working-upstream",
          version: "1",
          icons: [{ src: "https://tracker.example/icon.png", sizes: ["64x64"] }],
          websiteUrl: "https://tracker.example"
        }
      }
    } else if (message.method === "tools/list") {
      const cursor = message.params?.cursor
      result =
        cursor === undefined
          ? {
              nextCursor: "page-2",
              tools: [
                {
                  name: "lookup_project",
                  title: "Look up project",
                  description: "Find a project by name",
                  inputSchema: {
                    type: "object",
                    properties: { name: { type: "string" } },
                    required: ["name"]
                  }
                }
              ]
            }
          : {
              tools: [
                {
                  name: "list_issues",
                  inputSchema: { type: "object", properties: {} }
                }
              ]
            }
    } else if (message.method === "tools/call") {
      const params = UpstreamToolCallSchema.parse(message.params)
      calls.push(params)
      result =
        params.arguments?.binary === true
          ? {
              content: [
                {
                  type: "image",
                  mimeType: "image/png",
                  data: Buffer.from("gateway-binary-image").toString("base64")
                }
              ]
            }
          : { content: [{ type: "text", text: JSON.stringify(params) }] }
    } else {
      response.writeHead(400, { "content-type": "text/plain" })
      response.end("unexpected method")
      return
    }
    response.writeHead(200, {
      "content-type": "application/json",
      "mcp-session-id": "upstream-session"
    })
    response.end(JSON.stringify({ jsonrpc: "2.0", id: message.id, result }))
  })
  return { calls, requests, url: `${await listen(server)}/mcp` }
}

const ExecuteOutputSchema = z.object({ result: z.unknown() })

export const executeResultValue = (result: unknown): unknown => {
  const { content } = CallToolResultSchema.parse(result)
  const block = content.find((entry) => entry.type === "text")
  if (block?.type !== "text") throw new Error("The execute result has no text block")
  const decoded: unknown = JSON.parse(block.text)
  return ExecuteOutputSchema.parse(decoded).result
}

const ExecutionPayloadSchema = z.object({
  kind: z.literal("codevisor_execution"),
  execution: z.unknown()
})

export const executionOf = (event: RuntimeEvent): unknown =>
  ExecutionPayloadSchema.parse(event.payload).execution

export const connectionStateSettles = async (
  manager: McpManager,
  id: string,
  expected: string
): Promise<string> => {
  while (true) {
    const changed = Promise.withResolvers<void>()
    const unsubscribe = manager.subscribeServersChanged((changedId) => {
      if (changedId === id) changed.resolve()
    })
    try {
      const state = (await manager.list()).find((server) => server.id === id)?.connectionState ?? ""
      if (state === expected) return state
      await changed.promise
    } finally {
      unsubscribe()
    }
  }
}
