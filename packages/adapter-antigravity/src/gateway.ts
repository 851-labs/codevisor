import { createHash } from "node:crypto"
import { lstat, mkdir, readdir, readFile, rename, rm, symlink, writeFile } from "node:fs/promises"
import { join } from "node:path"

import type { ToolGatewayConfig } from "@codevisor/agent-runtime"

import { record } from "./protocol.js"

export const GATEWAY_URL_ENV = "CODEVISOR_MCP_GATEWAY_URL"
export const GATEWAY_TOKEN_ENV = "CODEVISOR_MCP_GATEWAY_TOKEN"

export const BRIDGE_SOURCE = String.raw`import { createInterface } from "node:readline"

const url = process.env.${GATEWAY_URL_ENV}
const token = process.env.${GATEWAY_TOKEN_ENV} ?? ""
const write = (message) => process.stdout.write(JSON.stringify(message) + "\n")
let session
let protocol
let listening = false

const headers = (accept) => ({
  authorization: "Bearer " + token,
  accept,
  ...(session === undefined ? {} : { "mcp-session-id": session }),
  ...(protocol === undefined ? {} : { "mcp-protocol-version": protocol })
})

const deliver = (message) => {
  const result = message && message.result
  if (result && typeof result.protocolVersion === "string" && result.serverInfo)
    protocol = result.protocolVersion
  write(message)
}

const events = async (body) => {
  const decoder = new TextDecoder()
  let buffer = ""
  for await (const chunk of body) {
    buffer += decoder.decode(chunk, { stream: true })
    let match
    while ((match = /\r?\n\r?\n/.exec(buffer)) !== null) {
      const block = buffer.slice(0, match.index)
      buffer = buffer.slice(match.index + match[0].length)
      const data = block
        .split(/\r?\n/)
        .filter((line) => line.startsWith("data:"))
        .map((line) => line.slice(5).replace(/^ /, ""))
        .join("\n")
      if (data === "") continue
      try {
        deliver(JSON.parse(data))
      } catch {}
    }
  }
}

const listen = async () => {
  if (listening) return
  listening = true
  try {
    const response = await fetch(url, { method: "GET", headers: headers("text/event-stream") })
    if (response.ok && response.body) await events(response.body)
  } catch {}
  listening = false
}

const fail = (message, text) => {
  if (message.id !== undefined && typeof message.method === "string")
    write({ jsonrpc: "2.0", id: message.id, error: { code: -32000, message: text } })
}

const post = async (message) => {
  let response
  try {
    response = await fetch(url, {
      method: "POST",
      headers: { ...headers("application/json, text/event-stream"), "content-type": "application/json" },
      body: JSON.stringify(message)
    })
  } catch (error) {
    fail(message, "Codevisor isn't reachable: " + error.message)
    return
  }
  session = response.headers.get("mcp-session-id") ?? session
  if (!response.ok) {
    fail(message, "Codevisor's tools answered HTTP " + response.status)
    return
  }
  const type = response.headers.get("content-type") ?? ""
  if (type.includes("text/event-stream") && response.body) await events(response.body)
  else if (type.includes("application/json")) {
    const value = await response.json()
    for (const entry of Array.isArray(value) ? value : [value]) deliver(entry)
  }
  if (message.method === "notifications/initialized") void listen()
}

const offline = (message) => {
  if (message.id === undefined || typeof message.method !== "string") return
  if (message.method === "initialize")
    write({
      jsonrpc: "2.0",
      id: message.id,
      result: {
        protocolVersion: (message.params && message.params.protocolVersion) || "2025-06-18",
        capabilities: { tools: {} },
        serverInfo: { name: "codevisor", version: "1" }
      }
    })
  else write({ jsonrpc: "2.0", id: message.id, result: message.method === "tools/list" ? { tools: [] } : {} })
}

createInterface({ input: process.stdin }).on("line", (line) => {
  let message
  try {
    message = JSON.parse(line)
  } catch {
    return
  }
  if (url) void post(message)
  else offline(message)
})
`

const BRIDGE_FILE = "codevisor-mcp-bridge.mjs"

const exists = (path: string) =>
  lstat(path).then(
    () => true,
    () => false
  )

const writeIfChanged = async (path: string, content: string, mode: number) => {
  const current = await readFile(path, "utf8").catch(() => undefined)
  if (current === content) return
  const temporary = `${path}.${process.pid}.tmp`
  await writeFile(temporary, content, { mode })
  await rm(path, { force: true })
  await rename(temporary, path)
}

const linkInto = async (from: string, to: string, skip: (name: string) => boolean) => {
  let names: Array<string>
  try {
    names = await readdir(from)
  } catch {
    return
  }
  await mkdir(to, { recursive: true })
  for (const name of names) {
    if (skip(name) || (await exists(join(to, name)))) continue
    await symlink(join(from, name), join(to, name)).catch(() => undefined)
  }
}

const prepareOverlay = async (overlay: string, own: string) => {
  await mkdir(join(own, "antigravity-cli"), { recursive: true })
  await linkInto(own, overlay, (name) => name === "config" || name.startsWith("."))
  await linkInto(join(own, "config"), join(overlay, "config"), (name) => name === "mcp_config.json")
}

export interface GatewaySetup {
  readonly args: ReadonlyArray<string>
  readonly env: Record<string, string>
}

export const prepareGateway = async (options: {
  readonly gateway: ToolGatewayConfig
  readonly geminiDir: string | undefined
  readonly home: string
  readonly overlays: string
  readonly node: string
}): Promise<GatewaySetup> => {
  const own = join(options.home, ".gemini")
  const root =
    options.geminiDir ??
    join(options.overlays, createHash("sha256").update(own).digest("hex").slice(0, 16), "gemini")
  if (options.geminiDir === undefined) await prepareOverlay(root, own)
  await mkdir(join(root, "config"), { recursive: true })
  const bridge = join(root, BRIDGE_FILE)
  await writeIfChanged(bridge, BRIDGE_SOURCE, 0o600)
  const theirs = await readFile(join(own, "config", "mcp_config.json"), "utf8")
    .then((text) => record(record(JSON.parse(text)).mcpServers))
    .catch(() => ({}))
  const config = {
    mcpServers: { ...theirs, [options.gateway.name]: { command: options.node, args: [bridge] } }
  }
  await writeIfChanged(
    join(root, "config", "mcp_config.json"),
    `${JSON.stringify(config, null, 2)}\n`,
    0o600
  )
  return {
    args: options.geminiDir === undefined ? [`--gemini_dir=${root}`] : [],
    env: {
      [GATEWAY_URL_ENV]: options.gateway.url,
      [GATEWAY_TOKEN_ENV]: options.gateway.bearerToken
    }
  }
}
