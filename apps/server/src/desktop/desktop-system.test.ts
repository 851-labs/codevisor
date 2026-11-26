import { mkdtempSync, readdirSync, rmSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"

import { describe, expect, it, onTestFinished } from "vitest"

import { processAlive, systemDesktopSystem } from "./desktop-system.js"

const openFiles = (): number => readdirSync("/dev/fd").length

describe("what the desktop code asks of the machine", () => {
  it("starts a detached process without keeping its log file open", () => {
    const folder = mkdtempSync(join(tmpdir(), "cv-detached-"))
    onTestFinished(() => rmSync(folder, { recursive: true, force: true }))
    const system = systemDesktopSystem()
    const before = openFiles()
    for (let run = 0; run < 5; run += 1)
      system.spawnDetached(process.execPath, ["-e", ""], join(folder, "desktop.log"))
    expect(openFiles()).toBe(before)
  })

  it("counts a process it may not signal, like another account's X server, as alive", () => {
    const ownedByRoot = 1
    expect(processAlive(ownedByRoot)).toBe(true)
    expect(processAlive(process.pid)).toBe(true)
  })
})
