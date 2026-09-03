import { makeDatabase } from "@codevisor/db"
import type { CodevisorDatabaseService } from "@codevisor/db"
import { Effect } from "effect"
import { createServer } from "node:http"
import type { Server } from "node:http"
import { mkdtempSync, rmSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { makeMcpManager } from "./mcp-manager.js"
import type { McpManager } from "./mcp-manager-types.js"
import { vi } from "vitest"

export const run = <A, E>(effect: Effect.Effect<A, E>): Promise<A> => Effect.runPromise(effect)

export const directories: string[] = []
export const databases: CodevisorDatabaseService[] = []
export const managers: McpManager[] = []
export const servers: Server[] = []

export const cleanupMcpManagerTests = async (): Promise<void> => {
  vi.restoreAllMocks()
  vi.unstubAllGlobals()
  vi.unstubAllEnvs()
  await Promise.all(managers.splice(0).map((manager) => manager.close()))
  await Promise.all(databases.splice(0).map((database) => run(database.close)))
  await Promise.all(
    servers
      .splice(0)
      .map(
        (server) =>
          new Promise<void>((resolve, reject) =>
            server.close((error) => (error === undefined ? resolve() : reject(error)))
          )
      )
  )
  for (const directory of directories.splice(0)) {
    rmSync(directory, { force: true, recursive: true })
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
  syncManagedSkills?: NonNullable<Parameters<typeof makeMcpManager>[0]["syncManagedSkills"]>,
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
    ...(syncManagedSkills === undefined ? {} : { syncManagedSkills }),
    ...extraConfig
  })
  managers.push(manager)
  return { db, manager, directory }
}

export const workingUpstream = async () => {
  const requests: Array<{
    headers: Record<string, string | string[] | undefined>
    method: string
  }> = []
  const calls: Array<{ name: string; arguments?: Record<string, unknown> }> = []
  const server = createServer(async (request, response) => {
    const chunks: Buffer[] = []
    for await (const chunk of request) chunks.push(Buffer.from(chunk))
    const message = JSON.parse(Buffer.concat(chunks).toString("utf8")) as {
      id?: string | number
      method: string
      params?: Record<string, unknown>
    }
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
        serverInfo: { name: "working-upstream", version: "1" }
      }
    } else if (message.method === "tools/list") {
      const cursor = (message.params as { cursor?: string } | undefined)?.cursor
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
      const params = message.params as {
        name: string
        arguments?: Record<string, unknown>
      }
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

/// Connections settle in the background after create/update: polls the
/// record until it reports `expected` (or the timeout lapses) and returns
/// the last observed state.
export const connectionStateSettles = async (
  manager: McpManager,
  id: string,
  expected: string,
  timeoutMs = 10_000
): Promise<string> => {
  const deadline = Date.now() + timeoutMs
  let state = ""
  while (Date.now() < deadline) {
    state = (await manager.list()).find((server) => server.id === id)?.connectionState ?? ""
    if (state === expected) return state
    await new Promise((resolve) => setTimeout(resolve, 25))
  }
  return state
}
