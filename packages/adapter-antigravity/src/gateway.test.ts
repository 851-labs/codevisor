import { spawn } from "node:child_process"
import {
  chmod,
  lstat,
  mkdir,
  mkdtemp,
  readFile,
  readlink,
  rm,
  symlink,
  writeFile
} from "node:fs/promises"
import { createServer, type IncomingMessage, type Server } from "node:http"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { createInterface } from "node:readline"

import { afterEach, describe, expect, it } from "vitest"

import { BRIDGE_SOURCE, prepareGateway } from "./gateway.js"
import { record } from "./protocol.js"

const roots: Array<string> = []
const cleanups: Array<() => unknown> = []
afterEach(async () => {
  const results = await Promise.allSettled(cleanups.splice(0).map(async (cleanup) => cleanup()))
  results.push(
    ...(await Promise.allSettled(
      roots.splice(0).map(async (root) => rm(root, { recursive: true, force: true }))
    ))
  )
  const errors: Array<unknown> = []
  for (const result of results) {
    if (result.status === "rejected") errors.push(result.reason)
  }
  if (errors.length > 0) throw new AggregateError(errors, "Failed to clean up agy gateway tests")
})
const temporary = async () => {
  const root = await mkdtemp(join(tmpdir(), "agy-gateway-"))
  roots.push(root)
  return root
}

const gateway = {
  name: "codevisor",
  url: "http://127.0.0.1:9/mcp?gateway=g1",
  bearerToken: "secret"
}

const home = async () => {
  const root = await temporary()
  const own = join(root, "home", ".gemini")
  await mkdir(join(own, "config", "skills"), { recursive: true })
  await mkdir(join(own, "antigravity"), { recursive: true })
  await writeFile(join(own, "GEMINI.md"), "rules")
  await writeFile(join(own, ".hidden"), "")
  await writeFile(
    join(own, "config", "mcp_config.json"),
    JSON.stringify({ mcpServers: { fs: { command: "npx", args: ["fs"] } } })
  )
  return { root, home: join(root, "home"), own }
}

const json = async (path: string) => JSON.parse(await readFile(path, "utf8")) as unknown

describe("Codevisor's gateway for agy", () => {
  it("adds the bridge beside an account's own servers, the chat's gateway in its environment", async () => {
    const { root, home: user, own } = await home()
    const gemini = join(root, "account", "gemini")
    await mkdir(join(gemini, "config"), { recursive: true })
    await symlink(join(own, "config", "mcp_config.json"), join(gemini, "config", "mcp_config.json"))

    const setup = await prepareGateway({
      gateway,
      geminiDir: gemini,
      home: user,
      overlays: join(root, "overlays"),
      node: "/bin/node"
    })
    expect(setup).toEqual({
      args: [],
      env: { CODEVISOR_MCP_GATEWAY_URL: gateway.url, CODEVISOR_MCP_GATEWAY_TOKEN: "secret" }
    })
    const bridge = join(gemini, "codevisor-mcp-bridge.mjs")
    expect(await readFile(bridge, "utf8")).toBe(BRIDGE_SOURCE)
    expect(await json(join(gemini, "config", "mcp_config.json"))).toEqual({
      mcpServers: {
        fs: { command: "npx", args: ["fs"] },
        codevisor: { command: "/bin/node", args: [bridge] }
      }
    })
    expect(await json(join(own, "config", "mcp_config.json"))).toEqual({
      mcpServers: { fs: { command: "npx", args: ["fs"] } }
    })
    expect((await lstat(join(gemini, "config", "mcp_config.json"))).isSymbolicLink()).toBe(false)
    expect(await readFile(join(gemini, "config", "mcp_config.json"), "utf8")).not.toContain(
      "secret"
    )

    await prepareGateway({
      gateway,
      geminiDir: gemini,
      home: user,
      overlays: root,
      node: "/bin/node"
    })
    expect(await readFile(bridge, "utf8")).toBe(BRIDGE_SOURCE)
  })

  it("runs the user's own agy on an overlay of their data, with Codevisor's MCP config", async () => {
    const { root, home: user, own } = await home()
    const setup = await prepareGateway({
      gateway,
      geminiDir: undefined,
      home: user,
      overlays: join(root, "overlays"),
      node: "/bin/node"
    })
    const overlay = setup.args[0]!.slice("--gemini_dir=".length)
    expect(overlay.startsWith(join(root, "overlays"))).toBe(true)
    for (const name of ["antigravity-cli", "antigravity", "GEMINI.md"])
      expect(await readlink(join(overlay, name))).toBe(join(own, name))
    expect(await readlink(join(overlay, "config", "skills"))).toBe(join(own, "config", "skills"))
    expect(await lstat(join(overlay, ".hidden")).catch(() => undefined)).toBeUndefined()
    expect(await json(join(overlay, "config", "mcp_config.json"))).toMatchObject({
      mcpServers: { fs: {}, codevisor: { command: "/bin/node" } }
    })
    const again = await prepareGateway({
      gateway,
      geminiDir: undefined,
      home: user,
      overlays: join(root, "overlays"),
      node: "/bin/node"
    })
    expect(again.args).toEqual(setup.args)
  })

  it("starts from no servers when the user has no readable MCP config", async () => {
    const root = await temporary()
    const user = join(root, "home")
    await mkdir(join(user, ".gemini", "config"), { recursive: true })
    await writeFile(join(user, ".gemini", "config", "mcp_config.json"), "{broken")
    const setup = await prepareGateway({
      gateway,
      geminiDir: undefined,
      home: user,
      overlays: join(root, "overlays"),
      node: "/bin/node"
    })
    const overlay = setup.args[0]!.slice("--gemini_dir=".length)
    expect(await json(join(overlay, "config", "mcp_config.json"))).toEqual({
      mcpServers: {
        codevisor: { command: "/bin/node", args: [join(overlay, "codevisor-mcp-bridge.mjs")] }
      }
    })
  })

  it("still prepares the overlay when a link can't be made", async () => {
    const { root, home: user } = await home()
    const overlays = join(root, "overlays")
    const first = await prepareGateway({
      gateway,
      geminiDir: undefined,
      home: user,
      overlays,
      node: "/bin/node"
    })
    const overlay = first.args[0]!.slice("--gemini_dir=".length)
    await writeFile(join(user, ".gemini", "AGENTS.md"), "more rules")
    await chmod(overlay, 0o500)
    cleanups.push(() => chmod(overlay, 0o700))
    await expect(
      prepareGateway({ gateway, geminiDir: undefined, home: user, overlays, node: "/bin/node" })
    ).resolves.toEqual(first)
  })
})

const read = async (request: IncomingMessage) => {
  let body = ""
  for await (const chunk of request) body += chunk
  return body === "" ? undefined : record(JSON.parse(body))
}

const fakeGateway = async () => {
  const seen: Array<{
    method: string
    session?: string
    protocol?: string
    auth?: string
    body?: unknown
  }> = []

  const server: Server = createServer(async (request, response) => {
    const body = await read(request)
    seen.push({
      method: request.method!,
      ...(typeof request.headers["mcp-session-id"] === "string"
        ? { session: request.headers["mcp-session-id"] }
        : {}),
      ...(typeof request.headers["mcp-protocol-version"] === "string"
        ? { protocol: request.headers["mcp-protocol-version"] }
        : {}),
      ...(request.headers.authorization === undefined
        ? {}
        : { auth: request.headers.authorization }),
      ...(body === undefined ? {} : { body })
    })
    if (request.method === "GET") {
      response.writeHead(200, { "content-type": "text/event-stream" })
      response.end(
        `event: message\ndata: ${JSON.stringify({ jsonrpc: "2.0", method: "notifications/tools/list_changed" })}\n\n`
      )
      return
    }
    const method = body?.method
    if (method === "initialize") {
      response.writeHead(200, { "content-type": "text/event-stream", "mcp-session-id": "s-1" })
      response.write(": keep-alive\n\n")
      response.end(
        `event: message\r\ndata: ${JSON.stringify({
          jsonrpc: "2.0",
          id: body!.id,
          result: {
            protocolVersion: "2025-06-18",
            capabilities: {},
            serverInfo: { name: "codevisor" }
          }
        })}\r\n\r\ndata: not json\n\n`
      )
    } else if (method === "tools/list") {
      response.writeHead(200, { "content-type": "application/json" })
      response.end(
        JSON.stringify({ jsonrpc: "2.0", id: body!.id, result: { tools: [{ name: "skills" }] } })
      )
    } else if (method === "tools/call") {
      response.writeHead(500)
      response.end()
    } else {
      response.writeHead(202)
      response.end()
    }
  })
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve))
  cleanups.push(() => new Promise((resolve) => server.close(resolve)))
  const address = server.address()
  if (address === null || typeof address === "string") throw new Error("gateway isn't on TCP")
  return { url: `http://127.0.0.1:${address.port}/mcp?gateway=g1`, seen }
}

const runBridge = async (env: Record<string, string>) => {
  const root = await temporary()
  const path = join(root, "bridge.mjs")
  await writeFile(path, BRIDGE_SOURCE)
  const child = spawn(process.execPath, [path], {
    env: { PATH: process.env.PATH ?? "", ...env },
    stdio: ["pipe", "pipe", "inherit"]
  })
  const closed = new Promise<void>((resolve) => child.once("close", () => resolve()))
  cleanups.push(async () => {
    child.kill()
    await closed
  })
  const received: Array<Record<string, unknown>> = []
  const waiting: Array<{
    match: (message: Record<string, unknown>) => boolean
    resolve: (message: Record<string, unknown>) => void
  }> = []
  createInterface({ input: child.stdout }).on("line", (line) => {
    const message = record(JSON.parse(line))
    received.push(message)
    for (const waiter of waiting.splice(0)) {
      if (waiter.match(message)) waiter.resolve(message)
      else waiting.push(waiter)
    }
  })
  const next = (match: (message: Record<string, unknown>) => boolean) => {
    const found = received.find(match)
    if (found !== undefined) return Promise.resolve(found)
    return new Promise<Record<string, unknown>>((resolve) => waiting.push({ match, resolve }))
  }
  const send = (message: unknown) =>
    child.stdin.write(`${typeof message === "string" ? message : JSON.stringify(message)}\n`)
  return { next, send, byId: (id: number) => next((message) => message.id === id) }
}

describe("the gateway bridge", () => {
  it("carries agy's MCP session to the chat's gateway and back", async () => {
    const remote = await fakeGateway()
    const bridge = await runBridge({
      CODEVISOR_MCP_GATEWAY_URL: remote.url,
      CODEVISOR_MCP_GATEWAY_TOKEN: "secret"
    })
    bridge.send("not json")
    bridge.send({
      jsonrpc: "2.0",
      id: 1,
      method: "initialize",
      params: { protocolVersion: "2025-06-18" }
    })
    expect(await bridge.byId(1)).toMatchObject({ result: { serverInfo: { name: "codevisor" } } })
    bridge.send({ jsonrpc: "2.0", method: "notifications/initialized" })
    expect(
      await bridge.next((message) => message.method === "notifications/tools/list_changed")
    ).toBeDefined()
    bridge.send({ jsonrpc: "2.0", id: 2, method: "tools/list" })
    expect(await bridge.byId(2)).toEqual({
      jsonrpc: "2.0",
      id: 2,
      result: { tools: [{ name: "skills" }] }
    })
    bridge.send({ jsonrpc: "2.0", id: 3, method: "tools/call", params: { name: "skills" } })
    expect(await bridge.byId(3)).toEqual({
      jsonrpc: "2.0",
      id: 3,
      error: { code: -32000, message: "Codevisor's tools answered HTTP 500" }
    })

    expect(remote.seen[0]).toEqual({
      method: "POST",
      auth: "Bearer secret",
      body: {
        jsonrpc: "2.0",
        id: 1,
        method: "initialize",
        params: { protocolVersion: "2025-06-18" }
      }
    })
    for (const request of remote.seen.slice(1))
      expect(request).toMatchObject({
        session: "s-1",
        protocol: "2025-06-18",
        auth: "Bearer secret"
      })
    expect(remote.seen.some((request) => request.method === "GET")).toBe(true)
  })

  it("answers agy's requests with an error when the gateway is unreachable", async () => {
    const bridge = await runBridge({
      CODEVISOR_MCP_GATEWAY_URL: "http://127.0.0.1:1/mcp",
      CODEVISOR_MCP_GATEWAY_TOKEN: "secret"
    })
    bridge.send({ jsonrpc: "2.0", method: "notifications/roots/list_changed" })
    bridge.send({ jsonrpc: "2.0", id: 1, method: "initialize", params: {} })
    expect(await bridge.byId(1)).toMatchObject({
      error: { code: -32000, message: expect.stringContaining("Codevisor isn't reachable") }
    })
  })

  it("is a server with no tools outside Codevisor", async () => {
    const bridge = await runBridge({})
    bridge.send({ jsonrpc: "2.0", method: "notifications/initialized" })
    bridge.send({
      jsonrpc: "2.0",
      id: 1,
      method: "initialize",
      params: { protocolVersion: "2025-03-26" }
    })
    expect(await bridge.byId(1)).toEqual({
      jsonrpc: "2.0",
      id: 1,
      result: {
        protocolVersion: "2025-03-26",
        capabilities: { tools: {} },
        serverInfo: { name: "codevisor", version: "1" }
      }
    })
    bridge.send({ jsonrpc: "2.0", id: 2, method: "initialize" })
    expect(await bridge.byId(2)).toMatchObject({ result: { protocolVersion: "2025-06-18" } })
    bridge.send({ jsonrpc: "2.0", id: 3, method: "tools/list" })
    expect(await bridge.byId(3)).toEqual({ jsonrpc: "2.0", id: 3, result: { tools: [] } })
    bridge.send({ jsonrpc: "2.0", id: 4, method: "ping" })
    expect(await bridge.byId(4)).toEqual({ jsonrpc: "2.0", id: 4, result: {} })
  })
})
