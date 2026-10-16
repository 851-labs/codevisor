import { mkdtempSync, rmSync, writeFileSync } from "node:fs"
import { createServer } from "node:net"
import { tmpdir } from "node:os"
import { join } from "node:path"

import { describe, expect, it, vi } from "vitest"

import {
  macComputerUseSocketPath,
  makeComputerUseProvider,
  requestMacScreenSharing
} from "./computer-use-provider.js"
import { expectRecord } from "./unknown-values.js"

describe("macOS Computer Use bridge discovery", () => {
  it("shares the native socket address across users and Unicode data paths", () => {
    const dataDir = "/Users/test/Codevisor café/data"
    expect(macComputerUseSocketPath(dataDir, 501)).toBe("/tmp/codevisor-cu-501-26606633.sock")
    expect(macComputerUseSocketPath(dataDir, 502)).not.toBe(macComputerUseSocketPath(dataDir, 501))
    expect(macComputerUseSocketPath(`${dataDir}/other`, 501)).not.toBe(
      macComputerUseSocketPath(dataDir, 501)
    )
  })

  it.skipIf(process.platform !== "darwin")(
    "discovers and authenticates the native bridge with a long worktree TMPDIR",
    async () => {
      const dataDir = mkdtempSync(join(tmpdir(), "codevisor-bridge-test-"))
      const socketPath = macComputerUseSocketPath(dataDir)
      const requests: Record<string, unknown>[] = []
      const server = createServer((socket) => {
        let pending = ""
        socket.on("data", (data) => {
          pending += data.toString()
          let newline: number
          while ((newline = pending.indexOf("\n")) >= 0) {
            const request = expectRecord(JSON.parse(pending.slice(0, newline)), "bridge request")
            pending = pending.slice(newline + 1)
            requests.push(request)
            socket.write(`${JSON.stringify({ id: request.id, result: { content: [] } })}\n`)
          }
        })
      })
      const provider = makeComputerUseProvider(dataDir)
      try {
        writeFileSync(join(dataDir, "computer-use-token"), "test-bridge-token", { mode: 0o600 })
        vi.stubEnv("CODEVISOR_COMPUTER_USE_SOCKET", undefined)
        vi.stubEnv("CODEVISOR_COMPUTER_USE_TOKEN", undefined)
        vi.stubEnv("TMPDIR", join(dataDir, "deep-worktree".repeat(20)))
        expect(provider.status().available).toBe(false)
        await new Promise<void>((resolve, reject) => {
          server.once("error", reject)
          server.listen(socketPath, resolve)
        })

        expect(provider.status().available).toBe(true)
        await provider.ensureSetup()
        expect(requests).toMatchObject([
          { type: "authenticate", token: "test-bridge-token" },
          { type: "tool", tool: "list_apps" }
        ])
      } finally {
        await provider.close()
        await new Promise<void>((resolve) => server.close(() => resolve()))
        vi.unstubAllEnvs()
        rmSync(dataDir, { recursive: true, force: true })
      }
    }
  )
})

describe("Computer Use turn lifecycle", () => {
  it.skipIf(process.platform !== "darwin")(
    "finishes only the used session and preserves its bridge and REPL for the next turn",
    async () => {
      const dataDir = mkdtempSync(join(tmpdir(), "codevisor-turn-bridge-"))
      const socketPath = macComputerUseSocketPath(dataDir)
      const requests: Record<string, unknown>[] = []
      const sockets = new Set<import("node:net").Socket>()
      const server = createServer((socket) => {
        sockets.add(socket)
        socket.once("close", () => sockets.delete(socket))
        let pending = ""
        socket.on("data", (data) => {
          pending += data.toString()
          let newline: number
          while ((newline = pending.indexOf("\n")) >= 0) {
            const request = expectRecord(JSON.parse(pending.slice(0, newline)), "bridge request")
            pending = pending.slice(newline + 1)
            requests.push(request)
            const result = {
              content: [
                {
                  type: "text",
                  text: JSON.stringify({ snapshotId: "s", windowId: 1, text: "Editor" })
                }
              ]
            }
            socket.write(`${JSON.stringify({ id: request.id, result })}\n`)
          }
        })
      })
      const provider = makeComputerUseProvider(dataDir)
      try {
        vi.stubEnv("CODEVISOR_COMPUTER_USE_SOCKET", socketPath)
        vi.stubEnv("CODEVISOR_COMPUTER_USE_TOKEN", "fixture-token")
        await new Promise<void>((resolve, reject) => {
          server.once("error", reject)
          server.listen(socketPath, resolve)
        })
        await provider.finishTurn!("unused")
        expect(requests).toEqual([])
        await provider.invoke({ sessionId: "a" }, "js", {
          code: 'let count=7; let app=await computer.getApp("Notes",{emit:false});'
        })
        await provider.invoke({ sessionId: "b" }, "get_app_state", { app: "Notes" })
        await provider.finishTurn!("a")
        expect(requests.filter((r) => r.type === "finishTurn")).toMatchObject([
          { type: "finishTurn", sessionId: "a" }
        ])
        const next = await provider.invoke({ sessionId: "a" }, "js", {
          code: "await app.getAXState(); ++count"
        })
        expect(next.content).toEqual([{ type: "text", text: "8" }])
        expect(requests.filter((r) => r.type === "authenticate")).toHaveLength(2)
        expect(sockets.size).toBe(2)
        expect(requests.some((r) => r.type === "closeSession")).toBe(false)
      } finally {
        await provider.close()
        for (const socket of sockets) socket.destroy()
        await new Promise<void>((resolve) => server.close(() => resolve()))
        vi.unstubAllEnvs()
        rmSync(dataDir, { recursive: true, force: true })
      }
    }
  )
})

describe("Computer Use execute deadlines", () => {
  it.skipIf(process.platform !== "darwin")(
    "sends the remaining budget, and a cancelled call drops its connection but keeps REPL bindings",
    async () => {
      const dataDir = mkdtempSync(join(tmpdir(), "codevisor-deadline-bridge-"))
      const socketPath = macComputerUseSocketPath(dataDir)
      const requests: Record<string, unknown>[] = []
      const sockets = new Set<import("node:net").Socket>()
      let held: { socket: import("node:net").Socket; request: Record<string, unknown> } | undefined
      let onHeld: (() => void) | undefined
      const server = createServer((socket) => {
        sockets.add(socket)
        socket.once("close", () => sockets.delete(socket))
        let pending = ""
        socket.on("data", (data) => {
          pending += data.toString()
          let newline: number
          while ((newline = pending.indexOf("\n")) >= 0) {
            const request = expectRecord(JSON.parse(pending.slice(0, newline)), "bridge request")
            pending = pending.slice(newline + 1)
            requests.push(request)
            if (expectRecord(request.arguments ?? {}, "arguments").view === "dialog") {
              held = { socket, request }
              onHeld?.()
              continue
            }
            const text = JSON.stringify({ snapshotId: "s", windowId: 1, text: "1 AXWindow Music" })
            const result = { content: [{ type: "text", text }] }
            socket.write(`${JSON.stringify({ id: request.id, result })}\n`)
          }
        })
      })
      const provider = makeComputerUseProvider(dataDir)
      try {
        vi.stubEnv("CODEVISOR_COMPUTER_USE_SOCKET", socketPath)
        vi.stubEnv("CODEVISOR_COMPUTER_USE_TOKEN", "fixture-token")
        await new Promise<void>((resolve, reject) => {
          server.once("error", reject)
          server.listen(socketPath, resolve)
        })
        await provider.invoke({ sessionId: "a" }, "js", {
          code: 'let count = 7; let music = await computer.getApp("Music", {emit: false});'
        })
        const deadline = new AbortController()
        const reachedNative = new Promise<void>((resolve) => (onHeld = resolve))
        const cancelled = provider.invoke(
          { sessionId: "a", signal: deadline.signal, deadline: performance.now() + 60_000 },
          "js",
          { code: 'await music.getAXState({view: "dialog"})' }
        )
        await reachedNative
        const budgetMs = held!.request.budgetMs
        expect(budgetMs).toBeGreaterThan(0)
        expect(budgetMs).toBeLessThanOrEqual(59_000)
        const droppedConnection = new Promise<void>((resolve) =>
          held!.socket.once("close", resolve)
        )
        deadline.abort(new Error("execute timed out after 60s"))
        expect(await cancelled).toMatchObject({
          isError: true,
          content: [{ type: "text", text: "execute timed out after 60s" }]
        })
        await droppedConnection

        const next = await provider.invoke({ sessionId: "a" }, "js", {
          code: "await music.getAXState(); count"
        })
        expect(next.content).toEqual([{ type: "text", text: "7" }])
        expect(requests.filter((r) => r.type === "authenticate")).toHaveLength(2)
      } finally {
        await provider.close()
        for (const socket of sockets) socket.destroy()
        await new Promise<void>((resolve) => server.close(() => resolve()))
        vi.unstubAllEnvs()
        rmSync(dataDir, { recursive: true, force: true })
      }
    }
  )
})

describe("native Screen Sharing bridge", () => {
  it.each(["success", "request failure", "authentication failure"])(
    "authenticates and closes its one-shot socket on %s",
    async (outcome) => {
      const dataDir = mkdtempSync(join(tmpdir(), "codevisor-sharing-bridge-"))
      const socketPath = macComputerUseSocketPath(dataDir)
      const requests: Record<string, unknown>[] = []
      const sockets = new Set<import("node:net").Socket>()
      let acknowledgeClose!: () => void
      const closed = new Promise<void>((resolve) => {
        acknowledgeClose = resolve
      })
      const server = createServer((socket) => {
        sockets.add(socket)
        socket.once("close", () => {
          sockets.delete(socket)
          acknowledgeClose()
        })
        let pending = ""
        socket.on("data", (data) => {
          pending += data.toString()
          let newline: number
          while ((newline = pending.indexOf("\n")) >= 0) {
            const request = expectRecord(JSON.parse(pending.slice(0, newline)), "bridge request")
            pending = pending.slice(newline + 1)
            requests.push(request)
            const failure =
              (outcome === "authentication failure" && request.type === "authenticate") ||
              (outcome === "request failure" && request.type === "screenSharing")
            socket.write(
              `${JSON.stringify({ id: request.id, ...(failure ? { error: "fixture failure" } : { result: { version: 1, status: "available", displays: [] } }) })}\n`
            )
          }
        })
      })
      try {
        vi.stubEnv("CODEVISOR_COMPUTER_USE_SOCKET", socketPath)
        vi.stubEnv("CODEVISOR_COMPUTER_USE_TOKEN", "fixture-token")
        await new Promise<void>((resolve, reject) => {
          server.once("error", reject)
          server.listen(socketPath, resolve)
        })
        const request = { version: 1, operation: "capabilities" }
        const operation = requestMacScreenSharing(dataDir, request)
        if (outcome === "success")
          await expect(operation).resolves.toEqual({
            version: 1,
            status: "available",
            displays: []
          })
        else await expect(operation).rejects.toThrow("fixture failure")
        await closed
        expect(requests[0]).toMatchObject({ type: "authenticate", token: "fixture-token" })
        if (outcome === "authentication failure") expect(requests).toHaveLength(1)
        else expect(requests[1]).toMatchObject({ type: "screenSharing", request })
      } finally {
        for (const socket of sockets) socket.destroy()
        await new Promise<void>((resolve) => server.close(() => resolve()))
        vi.unstubAllEnvs()
        rmSync(dataDir, { recursive: true, force: true })
      }
    }
  )
})
