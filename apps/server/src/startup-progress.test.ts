import { mkdtempSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { afterEach, describe, expect, it, vi } from "vitest"
import {
  makeStartupReporter,
  parseServeArgs,
  type ServerStartupProgress
} from "./startup-progress.js"

const directories: string[] = []
const directory = () => {
  const value = mkdtempSync(join(tmpdir(), "codevisor-startup-"))
  directories.push(value)
  return value
}
afterEach(() => {
  vi.restoreAllMocks()
  vi.unstubAllEnvs()
  directories.splice(0).forEach((dir) => rmSync(dir, { recursive: true, force: true }))
})

describe("startup checkpoints", () => {
  it("writes boot-scoped stages and counted work before HTTP is available", () => {
    const dir = directory()
    const args = { db: join(dir, "db.sqlite"), "boot-id": "this-boot" }
    const log = vi.fn()
    const reporter = makeStartupReporter(args, log)
    const read = (): ServerStartupProgress =>
      JSON.parse(readFileSync(join(dir, "server-startup.json"), "utf8"))
    reporter.checkpoint("loadingRuntime")
    expect(read()).toMatchObject({
      bootId: "this-boot",
      pid: process.pid,
      state: "starting",
      completed: 2,
      total: 7
    })
    expect(Date.parse(read().startedAt)).toBeLessThanOrEqual(Date.now())
    reporter.checkpoint("openingDatabase")
    reporter.work({ id: "migration", completed: 4, total: 10, name: "Updating history" })
    expect(read()).toMatchObject({ stage: "openingDatabase", work: { completed: 4, total: 10 } })
    expect(log).toHaveBeenCalledTimes(2)
    reporter.checkpoint("ready")
    expect(read()).toMatchObject({ state: "ready", completed: 6 })
    expect(read().work).toBeUndefined()
    expect(statSync(join(dir, "server-startup.json")).mode & 0o777).toBe(0o600)
    reporter.fail(new Error("database unavailable"))
    expect(read()).toMatchObject({ state: "failed", error: "database unavailable" })
    reporter.fail("import unavailable")
    expect(read().error).toBe("import unavailable")
  })

  it("assigns an identity once and resolves the configured status location", () => {
    const dir = directory()
    vi.stubEnv("CODEVISOR_DATA_DIR", dir)
    const args: Record<string, string> = {}
    const reporter = makeStartupReporter(args, () => {})
    reporter.checkpoint("acquiringDatabase")
    expect(args["boot-id"]).toBeTruthy()
    expect(JSON.parse(readFileSync(join(dir, "server-startup.json"), "utf8")).bootId).toBe(
      args["boot-id"]
    )
    const custom = join(dir, "custom.json")
    makeStartupReporter(
      { "startup-status": custom, db: join(dir, "other.sqlite") },
      () => {}
    ).checkpoint("restoringTerminals")
    expect(JSON.parse(readFileSync(custom, "utf8")).stage).toBe("restoringTerminals")
  })

  it("does not fail startup if checkpoint storage cannot be written", () => {
    const file = join(directory(), "file")
    writeFileSync(file, "not a directory")
    const log = vi.spyOn(console, "error").mockImplementation(() => {})
    const reporter = makeStartupReporter({ "startup-status": join(file, "status.json") })
    expect(() => reporter.checkpoint("initializingServices")).not.toThrow()
    expect(log.mock.calls.flat().join("\n")).toContain("Startup status unavailable")
  })

  it("preserves CLI argument parsing including missing values", () => {
    expect(parseServeArgs(["ignored", "--port", "1234", "--boot-id", "boot", "--db"])).toEqual({
      port: "1234",
      "boot-id": "boot",
      db: ""
    })
  })
})
