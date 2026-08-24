import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs"
import { createServer, type IncomingMessage, type Server } from "node:http"
import type { Socket } from "node:net"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { afterEach } from "vitest"
import { WebSocketServer } from "ws"
import type { PluginManifestV1 } from "@codevisor/api"
import type { InstalledPlugin } from "./plugin-store.js"
import type { PluginProcessHandle, PluginSpawnOptions } from "./plugin-supervisor.js"
import { makePluginsManager, type PluginsManager } from "./plugins-manager.js"
import { PluginsError } from "./plugins-error.js"

/// Shared fixtures for the supervisor and manager suites (same pattern as
/// apps/server's test-support.ts): in-process fake plugin servers, fake
/// spawners, and a manager factory wired to temp directories. Registered
/// cleanups run after every test in every importing file.

export const cleanups: Array<() => void> = []

afterEach(() => {
  for (const cleanup of cleanups.splice(0)) {
    cleanup()
  }
})

export const makeDir = (prefix: string): string => {
  const dir = mkdtempSync(join(tmpdir(), prefix))
  cleanups.push(() => rmSync(dir, { force: true, recursive: true }))
  return dir
}

export const makeDataDir = (): string => makeDir("codevisor-plugin-data-")

export const delay = (ms: number): Promise<void> =>
  new Promise((resolve) => setTimeout(resolve, ms))

/// An InstalledPlugin handed straight to the supervisor without a manifest
/// file on disk.
export const plugin = (overrides: Partial<PluginManifestV1> = {}): InstalledPlugin => ({
  directoryName: "example",
  id: "owner.example",
  manifest: {
    id: "owner.example",
    name: "Example",
    panes: [{ path: "/panes/main/", title: "Main", type: "main" }],
    protocolVersion: 1,
    run: { command: "run-me" },
    version: "0.1.0",
    ...overrides
  },
  path: makeDataDir(),
  source: "linked"
})

export interface FakeSpawn {
  readonly spawnShell: (command: string, options: PluginSpawnOptions) => PluginProcessHandle
  readonly spawnCount: () => number
  readonly simulateExit: (message: string) => void
}

/// Binds the assigned $PORT in-process so readiness probing sees a real
/// listener without any child processes.
export const fakeSpawn = (options: { readonly listen?: boolean } = {}): FakeSpawn => {
  let count = 0
  let server: Server | undefined
  const exitListeners: Array<(message: string) => void> = []
  cleanups.push(() => server?.close())
  return {
    simulateExit: (message) => {
      server?.close()
      for (const listener of exitListeners) {
        listener(message)
      }
    },
    spawnCount: () => count,
    spawnShell: (_command, spawnOptions) => {
      count += 1
      if (options.listen !== false) {
        server = createServer((_request, response) => response.end("ok"))
        server.listen(Number(spawnOptions.env["PORT"]), "127.0.0.1")
      }
      return {
        kill: () => server?.close(),
        onExit: (listener) => exitListeners.push(listener),
        pid: 4242
      }
    }
  }
}

export const writePlugin = (
  root: string,
  directoryName: string,
  manifest: Record<string, unknown>
): void => {
  const path = join(root, directoryName)
  mkdirSync(path, { recursive: true })
  writeFileSync(join(path, "codevisor-plugin.json"), JSON.stringify(manifest))
}

export const exampleManifest = {
  description: "Example plugin",
  id: "owner.example",
  name: "Example",
  panes: [{ path: "/panes/main/", title: "Main", type: "main" }],
  protocolVersion: 1 as const,
  run: { command: "run-me" },
  version: "0.1.0"
}

/// A tool-bearing plugin (panes empty — tool-only plugins are first-class).
/// The paths line up with makeFakePlugin's tool endpoints below.
export const toolManifest = {
  description: "Notes tools",
  id: "owner.notes",
  name: "Notes",
  panes: [],
  protocolVersion: 1 as const,
  run: { command: "run-me" },
  tools: [
    {
      description: "Append a note",
      inputSchema: {
        properties: { text: { type: "string" } },
        required: ["text"],
        type: "object"
      },
      name: "notes_add",
      path: "/tools/add"
    },
    { description: "List saved notes as text", name: "notes_list", path: "/tools/text" },
    {
      description: "Answers without a content type",
      name: "notes_untyped",
      path: "/tools/untyped"
    },
    { description: "Always fails", name: "notes_fail", path: "/tools/fail" },
    { description: "404s with an empty body", name: "notes_missing", path: "/tools/missing" },
    { description: "Returns malformed JSON", name: "notes_bad_json", path: "/tools/bad-json" },
    { description: "Never responds", name: "notes_slow", path: "/tools/slow" }
  ],
  version: "0.1.0"
}

export interface RecordedRequest {
  readonly path: string
  readonly method: string
  readonly body: string
  readonly headers: IncomingMessage["headers"]
}

export interface FakePlugin {
  readonly requests: Array<RecordedRequest>
  readonly spawnCount: () => number
  readonly simulateExit: (message: string) => void
  readonly spawnShell: (
    command: string,
    options: PluginSpawnOptions
  ) => {
    readonly kill: () => void
    readonly onExit: (listener: (message: string) => void) => void
    readonly pid: number
  }
  readonly stop: () => void
}

/// An in-process stand-in for a plugin server: binds the assigned $PORT and
/// records every request so tests can assert on exactly what crossed the
/// proxy.
export const makeFakePlugin = (): FakePlugin => {
  let server: Server | undefined
  let spawns = 0
  let exitListeners: Array<(message: string) => void> = []
  const requests: Array<RecordedRequest> = []
  cleanups.push(() => server?.close())
  return {
    requests,
    spawnCount: () => spawns,
    simulateExit: (message) => {
      server?.close()
      for (const listener of exitListeners) {
        listener(message)
      }
    },
    spawnShell: (_command, options) => {
      spawns += 1
      exitListeners = []
      server = createServer((request, response) => {
        const chunks: Array<Buffer> = []
        request.on("data", (chunk: Buffer) => chunks.push(chunk))
        request.on("end", () => {
          requests.push({
            body: Buffer.concat(chunks).toString("utf8"),
            headers: request.headers,
            method: request.method ?? "",
            path: request.url ?? ""
          })
          const url = new URL(request.url ?? "/", "http://127.0.0.1")
          if (url.pathname === "/panes/main/") {
            response.writeHead(200, { "Content-Type": "text/html" })
            response.end("<html>pane</html>")
            return
          }
          if (url.pathname === "/panes/main/asset.js") {
            response.writeHead(200, { "Content-Type": "text/javascript" })
            response.end("console.log(1)")
            return
          }
          if (url.pathname === "/panes/main/cookies") {
            response.writeHead(200, { "set-cookie": "plugincookie=1" })
            response.end("cookies")
            return
          }
          if (url.pathname === "/assets/icon.svg" || url.pathname === "/assets/pane.svg") {
            response.writeHead(200, { "Content-Type": "image/svg+xml" })
            response.end(
              '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"><rect width="24" height="24" fill="#7657e8"/></svg>'
            )
            return
          }
          if (url.pathname === "/panes/main/never" || url.pathname === "/tools/slow") {
            return
          }
          if (url.pathname === "/tools/add") {
            response.writeHead(200, { "Content-Type": "application/json" })
            response.end(
              JSON.stringify({
                ok: true,
                received: JSON.parse(
                  chunks.length === 0 ? "{}" : Buffer.concat(chunks).toString("utf8")
                )
              })
            )
            return
          }
          if (url.pathname === "/tools/text") {
            response.writeHead(200, { "Content-Type": "text/plain" })
            response.end("two notes")
            return
          }
          if (url.pathname === "/tools/untyped") {
            response.writeHead(200)
            response.end("untyped")
            return
          }
          if (url.pathname === "/tools/fail") {
            response.writeHead(500, { "Content-Type": "text/plain" })
            response.end("boom")
            return
          }
          if (url.pathname === "/tools/bad-json") {
            response.writeHead(200, { "Content-Type": "application/json" })
            response.end("{")
            return
          }
          response.writeHead(404)
          response.end()
        })
      })
      const webSocketServer = new WebSocketServer({ noServer: true })
      server.on("upgrade", (request, socket, head) => {
        requests.push({
          body: "",
          headers: request.headers,
          method: request.method ?? "",
          path: request.url ?? ""
        })
        webSocketServer.handleUpgrade(request, socket, head, (webSocket) => {
          webSocket.on("message", (data) => webSocket.send(`echo:${String(data)}`))
        })
      })
      server.listen(Number(options.env["PORT"]), "127.0.0.1")
      return {
        kill: () => server?.close(),
        onExit: (listener) => exitListeners.push(listener),
        pid: 1
      }
    },
    stop: () => server?.close()
  }
}

/// Hosts the manager behind a real HTTP server the way apps/server does:
/// proxy-shaped requests go to the manager pre-auth, everything else 404s.
export const makeOuterServer = async (
  manager: PluginsManager
): Promise<{ readonly origin: string; readonly port: number }> => {
  const server = createServer((request, response) => {
    const url = new URL(request.url ?? "/", "http://127.0.0.1")
    void manager
      .handleProxyRequest(request, response, url)
      .then((handled) => {
        if (!handled) {
          response.writeHead(404)
          response.end()
        }
      })
      .catch((cause: unknown) => {
        const status = cause instanceof PluginsError ? (cause.code === "notFound" ? 404 : 400) : 500
        response.writeHead(status, { "Content-Type": "application/json" })
        response.end(JSON.stringify({ error: String(cause) }))
      })
  })
  server.on("upgrade", (request, socket, head) => {
    void manager.handleUpgrade(request, socket as Socket, head).then((handled) => {
      if (!handled) {
        socket.destroy()
      }
    })
  })
  cleanups.push(() => server.close())
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve))
  const address = server.address()
  const port = typeof address === "object" && address !== null ? address.port : 0
  return { origin: `http://127.0.0.1:${port}`, port }
}

export const makeManager = (
  overrides: Partial<Parameters<typeof makePluginsManager>[0]> = {},
  manifest: Record<string, unknown> = exampleManifest
): { manager: PluginsManager; root: string; fake: FakePlugin } => {
  const root = makeDir("codevisor-plugins-root-")
  writePlugin(root, "example", manifest)
  const fake = makeFakePlugin()
  const manager = makePluginsManager({
    dataDir: makeDir("codevisor-plugins-data-"),
    log: () => undefined,
    now: Date.now,
    pluginsRoot: root,
    readyTimeoutMs: 5_000,
    resolveEnv: async () => ({}),
    spawnShell: fake.spawnShell,
    ...overrides
  })
  cleanups.push(() => manager.close())
  return { fake, manager, root }
}
