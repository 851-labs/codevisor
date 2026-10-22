import { mkdtempSync, rmSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"

import { afterEach, describe, expect, it, vi } from "vitest"

import type { BootListener } from "./boot-listener.js"
import { readListenPort } from "./infra/listen-port.js"
import { claimServeListener } from "./serve-listener.js"

const boot = {
  host: "127.0.0.1",
  version: "0.1.0",
  bootId: "boot-1",
  processId: 42,
  appOwned: false,
  serviceManaged: false
}

const directories: Array<string> = []
const listeners: Array<BootListener> = []

afterEach(async () => {
  for (const listener of listeners.splice(0)) await listener.close()
  for (const directory of directories.splice(0)) rmSync(directory, { recursive: true, force: true })
})

const dataDir = (): string => {
  const directory = mkdtempSync(join(tmpdir(), "codevisor-serve-listener-"))
  directories.push(directory)
  return directory
}

describe("claimServeListener", () => {
  it("serves on a pinned port and records it for clients", async () => {
    const directory = dataDir()
    const lines: Array<string> = []

    const { listener, plan } = await claimServeListener({
      args: { port: "0" },
      env: {},
      dataDir: directory,
      boot: { ...boot, log: (line) => lines.push(line) }
    })
    listeners.push(listener)

    expect(plan).toEqual({ kind: "pinned", port: 0 })
    expect(readListenPort(directory)).toBe(listener.port)
    expect(lines).toEqual([`Codevisor server claimed port ${listener.port}`])
  })

  it("keeps serving when the port cannot be recorded", async () => {
    const blockedDir = join(dataDir(), "not-a-directory")
    writeFileSync(blockedDir, "")
    const error = vi.spyOn(console, "error").mockImplementation(() => undefined)
    try {
      const { listener } = await claimServeListener({
        args: { port: "0" },
        env: {},
        dataDir: blockedDir,
        boot
      })
      listeners.push(listener)

      expect(error.mock.calls.map(([line]) => String(line))).toEqual([
        `Codevisor server claimed port ${listener.port}`,
        expect.stringContaining("Could not record the listening port:")
      ])
    } finally {
      error.mockRestore()
    }
  })
})
