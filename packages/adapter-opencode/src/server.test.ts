import { EventEmitter } from "node:events"

import { describe, expect, it } from "vitest"

import { OpenCodeServerError, startOpenCodeServer, type OpenCodeChild } from "./server.js"

/// A scripted `opencode serve --stdio`: tests print its lines and decide
/// whether closing stdin ends it.
class FakeChild extends EventEmitter implements OpenCodeChild {
  readonly stdout = new EventEmitter()
  readonly stderr = new EventEmitter()
  exitCode: number | null = null
  readonly signals: Array<NodeJS.Signals | undefined> = []
  stdinClosed = false
  exitsWhenStdinCloses = true
  readonly stdin = {
    end: () => {
      this.stdinClosed = true
      if (this.exitsWhenStdinCloses) this.exit(0)
    }
  }
  readonly kill = (signal?: NodeJS.Signals) => {
    this.signals.push(signal)
    this.exit(null)
    return true
  }
  exit(code: number | null) {
    if (this.exitCode !== null) return
    this.exitCode = code ?? 1
    this.emit("exit", code)
  }
  print(line: string) {
    this.stdout.emit("data", `${line}\n`)
  }
}

const json = (status: number, body?: unknown) =>
  new Response(body === undefined ? null : JSON.stringify(body), { status })

const harness = (responses: (url: URL) => Response) => {
  const child = new FakeChild()
  const spawned: Array<{ args: ReadonlyArray<string>; env: NodeJS.ProcessEnv }> = []
  const requests: Array<{ url: URL; init: RequestInit }> = []
  const waits: number[] = []
  const start = () =>
    startOpenCodeServer({
      command: "/bin/opencode",
      env: { HOME: "/home/test" },
      spawnChild: (_command, args, options) => {
        spawned.push({ args, env: options.env })
        return child
      },
      fetch: (async (input: URL, init: RequestInit) => {
        requests.push({ url: input, init })
        return responses(input)
      }) as typeof fetch,
      wait: async (ms) => {
        waits.push(ms)
      }
    })
  return { child, spawned, requests, waits, start }
}

describe("OpenCode 2 server", () => {
  it("starts on a leased stdio server, waits until it is ready, and authenticates requests", async () => {
    let info = 0
    const h = harness((url) => {
      if (url.pathname === "/api/info")
        return ++info < 3 ? json(503) : json(200, { version: "2.0.24" })
      if (url.pathname === "/api/credential" && url.search === "")
        return json(409, { message: "Credential already exists" })
      if (url.pathname === "/api/credential/x") return json(204)
      return json(200, { data: [url.searchParams.get("location[directory]")] })
    })
    const pending = h.start()
    h.child.print('{"url":"http://127.0.0.1:4100/"}')
    const server = await pending

    expect(server.url).toBe("http://127.0.0.1:4100")
    expect(h.spawned[0]?.args).toEqual(["serve", "--stdio", "--port", "0"])
    const password = h.spawned[0]?.env.OPENCODE_PASSWORD
    expect(password).toMatch(/^[\w-]{32}$/)
    expect(h.spawned[0]?.env.HOME).toBe("/home/test")
    // Two "still booting" answers, one poll interval after each.
    expect(h.waits).toEqual([250, 250])
    expect(new Headers(h.requests[0]?.init.headers).get("authorization")).toBe(
      `Basic ${Buffer.from(`opencode:${password}`).toString("base64")}`
    )

    expect(await server.request("/api/integration", { location: "/work" })).toEqual({
      data: ["/work"]
    })
    await expect(server.request("/api/credential", { body: { id: "x" } })).rejects.toMatchObject({
      message: "Credential already exists",
      status: 409
    })
    const post = h.requests.at(-1)
    expect(post?.init.method).toBe("POST")
    expect(new Headers(post?.init.headers).get("content-type")).toBe("application/json")
    expect(await server.request("/api/credential/x", { method: "DELETE" })).toBeUndefined()

    await server.stop()
    expect(h.child.stdinClosed).toBe(true)
    expect(h.child.signals).toEqual([])
  })

  it("explains a server that exits, fails to spawn, or prints something unexpected before starting", async () => {
    const exits = harness(() => json(200))
    const exited = exits.start()
    exits.child.stderr.emit("data", "Error: unknown option --stdio\n")
    exits.child.exit(2)
    await expect(exited).rejects.toThrow("unknown option --stdio")

    const silent = harness(() => json(200))
    const silentExit = silent.start()
    silent.child.exit(3)
    await expect(silentExit).rejects.toThrow("exited before it started (status 3)")

    const missing = harness(() => json(200))
    const spawnFailure = missing.start()
    missing.child.emit("error", new Error("spawn opencode ENOENT"))
    await expect(spawnFailure).rejects.toThrow("spawn opencode ENOENT")

    const garbled = harness(() => json(200))
    const unexpected = garbled.start()
    garbled.child.print("opencode server listening on http://127.0.0.1:4100")
    await expect(unexpected).rejects.toBeInstanceOf(OpenCodeServerError)
    expect(garbled.child.stdinClosed).toBe(true)
  })

  it("gives up on a server that never becomes ready, and stops it", async () => {
    const h = harness(() => json(503))
    const pending = h.start()
    h.child.print('{"url":"http://127.0.0.1:4100"}')
    await expect(pending).rejects.toThrow("did not start within 30 seconds")
    // 30 seconds of 250ms polls (the last wait is the stop's grace period).
    expect(h.waits.filter((ms) => ms === 250)).toHaveLength(120)
    expect(h.child.stdinClosed).toBe(true)

    const broken = harness(() => json(500, { message: "database is locked" }))
    const failed = broken.start()
    broken.child.print('{"url":"http://127.0.0.1:4100"}')
    await expect(failed).rejects.toThrow("database is locked")
    expect(broken.child.stdinClosed).toBe(true)
  })

  it("kills a server that ignores the end of its lease, once", async () => {
    const h = harness(() => json(200))
    h.child.exitsWhenStdinCloses = false
    const pending = h.start()
    h.child.print('{"url":"http://127.0.0.1:4100"}')
    const server = await pending
    await Promise.all([server.stop(), server.stop()])
    expect(h.child.signals).toEqual(["SIGKILL"])
    expect(h.waits).toEqual([1000])
    await server.stop()
    expect(h.child.signals).toEqual(["SIGKILL"])
  })
})
