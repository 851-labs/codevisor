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

describe("macOS Computer Use bridge discovery", () => {
  it("shares the native socket address across users and Unicode data paths", () => {
    // The native test uses this same fixture to check the wire contract.
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
            const request = JSON.parse(pending.slice(0, newline)) as Record<string, unknown>
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
            const request = JSON.parse(pending.slice(0, newline)) as Record<string, unknown>
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
