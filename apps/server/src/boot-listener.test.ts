import { afterEach, describe, expect, it, vi } from "vitest"
import { WebSocket } from "ws"

import { claimBootListener, type BootListener } from "./boot-listener.js"
import { hasExistingListener } from "./infra/listener-probe.js"
import { listeningPort } from "./test-support-net.js"

const options = {
  host: "127.0.0.1",
  candidates: [0],
  version: "0.3.0",
  bootId: "boot-1",
  processId: 4242,
  appOwned: true,
  serviceManaged: true,
  buildNumber: 300,
  log: () => undefined
}

describe("boot listener", () => {
  const open: Array<BootListener> = []
  afterEach(async () => {
    for (const listener of open.splice(0)) await listener.close()
  })

  it("answers health with the latest upgrade report and refuses everything else", async () => {
    const listener = await claimBootListener(options)
    open.push(listener)
    const base = `http://127.0.0.1:${listener.port}`

    const initial = await fetch(`${base}/v1/health`)
    expect(initial.status).toBe(200)
    expect(initial.headers.get("connection")).toBe("close")
    expect(await initial.json()).toEqual({
      ok: false,
      version: "0.3.0",
      database: "migrating",
      bootId: "boot-1",
      processId: 4242,
      appOwned: true,
      serviceManaged: true,
      buildNumber: 300
    })

    listener.report({
      state: "running",
      id: "canonical-session-chat-v1",
      name: "Updating chat history",
      completed: 40,
      total: 100
    })
    expect(await (await fetch(`${base}/v1/health?probe=1`)).json()).toMatchObject({
      ok: false,
      database: "migrating",
      migration: {
        id: "canonical-session-chat-v1",
        name: "Updating chat history",
        completed: 40,
        total: 100
      }
    })

    listener.report({
      state: "failed",
      id: "database-startup",
      name: "Applying update",
      completed: 0,
      total: 0,
      error: "disk full"
    })
    expect(await (await fetch(`${base}/v1/health`)).json()).toMatchObject({
      database: "failed",
      migration: { id: "database-startup", error: "disk full" }
    })

    const refused = await fetch(`${base}/v1/info`)
    expect(refused.status).toBe(503)
    expect(await refused.json()).toEqual({ error: "Server is updating its data" })
    expect((await fetch(`${base}/v1/health`, { method: "POST" })).status).toBe(503)

    await new Promise<void>((resolve, reject) => {
      const socket = new WebSocket(`ws://127.0.0.1:${listener.port}/v1/events`)
      socket.once("error", () => resolve())
      socket.once("open", () => reject(new Error("Event stream opened during boot")))
    })
  })

  it("hands the socket to replacement handlers and frees the port on close", async () => {
    const listener = await claimBootListener(options)
    open.push(listener)
    const port = listener.port
    expect(port).toBe(listeningPort(listener.server))

    listener.detach()
    listener.server.on("request", (_request, response) => {
      response.writeHead(200, { "Content-Type": "application/json" })
      response.end(JSON.stringify({ ok: true }))
    })
    expect(await (await fetch(`http://127.0.0.1:${port}/v1/health`)).json()).toEqual({ ok: true })

    await open.pop()!.close()
    expect(await hasExistingListener("127.0.0.1", port)).toBe(false)
  })

  it("logs a failed accept instead of exiting, and keeps answering", async () => {
    const lines: Array<string> = []
    const listener = await claimBootListener({ ...options, log: (line) => lines.push(line) })
    open.push(listener)
    listener.server.emit("error", Object.assign(new Error("accept EMFILE"), { code: "EMFILE" }))
    expect(lines).toEqual(["Early health listener error: accept EMFILE"])
    expect((await fetch(`http://127.0.0.1:${listener.port}/v1/health`)).status).toBe(200)
  })

  it("reports socket errors through the console when no log sink is supplied", async () => {
    const { log: _omitted, ...quiet } = options
    const listener = await claimBootListener(quiet)
    open.push(listener)
    const error = vi.spyOn(console, "error").mockImplementation(() => undefined)
    try {
      listener.server.emit("error", new Error("accept EMFILE"))
      expect(error).toHaveBeenCalledExactlyOnceWith("Early health listener error: accept EMFILE")
    } finally {
      error.mockRestore()
    }
  })

  it("keeps answering for the grace window before closing after a failed upgrade", async () => {
    const listener = await claimBootListener(options)
    open.push(listener)
    vi.useFakeTimers({ toFake: ["setTimeout"] })
    try {
      const closed = vi.fn()
      const closing = open.pop()!.close({ afterMs: 10_000 }).then(closed)
      await vi.advanceTimersByTimeAsync(9_999)
      expect(closed).not.toHaveBeenCalled()
      expect(listener.server.listening).toBe(true)
      await vi.advanceTimersByTimeAsync(1)
      await closing
      expect(closed).toHaveBeenCalledOnce()
      expect(listener.server.listening).toBe(false)
    } finally {
      vi.useRealTimers()
    }
  })

  it("falls back to the default version so clients can decode dev builds", async () => {
    const listener = await claimBootListener({
      ...options,
      version: undefined,
      sourceRevision: "abc123"
    })
    open.push(listener)

    const health = await fetch(`http://127.0.0.1:${listener.port}/v1/health`)

    expect(await health.json()).toMatchObject({
      version: "0.1.0",
      database: "migrating",
      sourceRevision: "abc123"
    })
  })
})
