import type { AddressInfo } from "node:net"
import { createServer } from "node:net"

import { afterEach, describe, expect, it, vi } from "vitest"
import { WebSocket } from "ws"

import {
  bootHealth,
  startBootListener,
  startBootListenerIfPortFree,
  type BootListener
} from "./boot-listener.js"
import { hasExistingListener } from "./infra/listener-probe.js"

const options = {
  host: "127.0.0.1",
  port: 0,
  version: "0.3.0",
  bootId: "boot-1",
  processId: 4242,
  appOwned: true,
  serviceManaged: true,
  buildNumber: 300,
  log: () => undefined
}

const portOf = (listener: BootListener): number => (listener.server.address() as AddressInfo).port

describe("boot listener", () => {
  const open: Array<BootListener> = []
  afterEach(async () => {
    for (const listener of open.splice(0)) await listener.close()
  })

  it("answers health with the latest upgrade report and refuses everything else", async () => {
    const listener = await startBootListener(options)
    expect(listener).toBeDefined()
    open.push(listener!)
    const base = `http://127.0.0.1:${portOf(listener!)}`

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

    listener!.report({
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

    listener!.report({
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
      const socket = new WebSocket(`ws://127.0.0.1:${portOf(listener!)}/v1/events`)
      socket.once("error", () => resolve())
      socket.once("open", () => reject(new Error("Event stream opened during boot")))
    })
  })

  it("hands the socket to replacement handlers and frees the port on close", async () => {
    const listener = await startBootListener(options)
    open.push(listener!)
    const port = portOf(listener!)

    listener!.detach()
    listener!.server.on("request", (_request, response) => {
      response.writeHead(200, { "Content-Type": "application/json" })
      response.end(JSON.stringify({ ok: true }))
    })
    expect(await (await fetch(`http://127.0.0.1:${port}/v1/health`)).json()).toEqual({ ok: true })

    await open.pop()!.close()
    expect(await hasExistingListener("127.0.0.1", port)).toBe(false)
  })

  it("steps aside instead of failing when the port is taken", async () => {
    const first = await startBootListener(options)
    open.push(first!)
    const lines: Array<string> = []
    const second = await startBootListener({
      ...options,
      port: portOf(first!),
      log: (line) => lines.push(line)
    })
    expect(second).toBeUndefined()
    expect(lines).toHaveLength(1)
    expect(lines[0]).toContain("Early health listener unavailable")
  })

  it("binds a free fixed port, but never a live listener or an ephemeral port", async () => {
    expect(await startBootListenerIfPortFree(options)).toBeUndefined()

    // A port the OS just handed out and released is free for the bind.
    const freePort = await new Promise<number>((resolve) => {
      const probe = createServer()
      probe.listen(0, "127.0.0.1", () => {
        const port = (probe.address() as AddressInfo).port
        probe.close(() => resolve(port))
      })
    })
    const bound = await startBootListenerIfPortFree({ ...options, port: freePort })
    expect(bound).toBeDefined()
    open.push(bound!)
    expect(portOf(bound!)).toBe(freePort)

    const live = await startBootListener(options)
    open.push(live!)
    const lines: Array<string> = []
    expect(
      await startBootListenerIfPortFree({
        ...options,
        port: portOf(live!),
        log: (line) => lines.push(line)
      })
    ).toBeUndefined()
    expect(lines).toEqual([
      `127.0.0.1:${portOf(live!)} already has a listener; skipping the early health listener`
    ])
  })

  it("reports through the console when no log sink is supplied", async () => {
    const live = await startBootListener(options)
    open.push(live!)
    const { log: _omitted, ...quiet } = options
    const error = vi.spyOn(console, "error").mockImplementation(() => undefined)
    try {
      expect(await startBootListenerIfPortFree({ ...quiet, port: portOf(live!) })).toBeUndefined()
      expect(await startBootListener({ ...quiet, port: portOf(live!) })).toBeUndefined()
      expect(error.mock.calls.map(([line]) => String(line))).toEqual([
        expect.stringContaining("already has a listener"),
        expect.stringContaining("Early health listener unavailable")
      ])
    } finally {
      error.mockRestore()
    }
  })

  it("keeps answering for the grace window before closing after a failed upgrade", async () => {
    const listener = await startBootListener(options)
    open.push(listener!)
    vi.useFakeTimers({ toFake: ["setTimeout"] })
    try {
      const closed = vi.fn()
      const closing = open.pop()!.close({ afterMs: 10_000 }).then(closed)
      await vi.advanceTimersByTimeAsync(9_999)
      expect(closed).not.toHaveBeenCalled()
      expect(listener!.server.listening).toBe(true)
      await vi.advanceTimersByTimeAsync(1)
      await closing
      expect(closed).toHaveBeenCalledOnce()
      expect(listener!.server.listening).toBe(false)
    } finally {
      vi.useRealTimers()
    }
  })

  it("falls back to the default version so clients can decode dev builds", () => {
    expect(bootHealth({ ...options, version: undefined }, undefined)).toMatchObject({
      version: "0.1.0",
      database: "migrating"
    })
    expect(bootHealth({ ...options, sourceRevision: "abc123" }, undefined)).toMatchObject({
      version: "0.3.0",
      sourceRevision: "abc123"
    })
  })
})
