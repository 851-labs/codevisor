import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs"
import { dirname, join } from "node:path"
import { describe, expect, it } from "vitest"
import { makeDir } from "./test-support.js"
import { makePluginTransactionEngine, type PluginTransactionPaths } from "./plugin-transaction.js"

const write = (path: string, content: string): void => {
  mkdirSync(dirname(path), { recursive: true })
  writeFileSync(path, content)
}

const text = (path: string): string => readFileSync(path, "utf8")

interface Fixture {
  readonly paths: PluginTransactionPaths
  readonly engine: ReturnType<typeof makePluginTransactionEngine>
  readonly stops: Array<string>
}

const fixture = (verifyInstalled: (pluginId: string) => Promise<void>): Fixture => {
  const pluginsRoot = makeDir("codevisor-plugin-transactions-")
  const pluginDataRoot = makeDir("codevisor-plugin-transaction-data-")
  const stops: Array<string> = []
  const engine = makePluginTransactionEngine({
    pluginDataRoot,
    pluginsRoot,
    stop: (pluginId) => stops.push(pluginId),
    verifyInstalled
  })
  return { engine, paths: engine.paths("owner.example"), stops }
}

const writeJournal = (
  paths: PluginTransactionPaths,
  phase: string,
  overrides: Record<string, unknown> = {}
): void => {
  write(
    paths.journal,
    JSON.stringify({
      hadData: true,
      hadExisting: true,
      phase,
      pluginId: "owner.example",
      schemaVersion: 1,
      ...overrides
    })
  )
}

describe("plugin transactions", () => {
  it("swaps a verified candidate and retains one known-good code/data backup", async () => {
    let paths!: PluginTransactionPaths
    const current = fixture(async () => {
      expect(text(join(paths.destination, "version.txt"))).toBe("new")
      write(join(paths.data, "value.txt"), "candidate-data")
    })
    paths = current.paths
    write(join(paths.destination, "version.txt"), "old")
    write(join(paths.candidate, "version.txt"), "new")
    write(join(paths.data, "value.txt"), "old-data")

    await current.engine.apply("owner.example", true)

    expect(text(join(paths.destination, "version.txt"))).toBe("new")
    expect(text(join(paths.knownGoodCode, "version.txt"))).toBe("old")
    expect(text(join(paths.data, "value.txt"))).toBe("candidate-data")
    expect(text(join(paths.knownGoodData, "value.txt"))).toBe("old-data")
    expect(existsSync(paths.journal)).toBe(false)
    expect(current.stops).toEqual(["owner.example"])
  })

  it("restores code, data, and the old process when candidate verification fails", async () => {
    let paths!: PluginTransactionPaths
    let restarted = 0
    const current = fixture(async () => {
      if (existsSync(join(paths.destination, "new.txt"))) {
        write(join(paths.data, "value.txt"), "candidate-data")
        throw new Error("candidate unhealthy")
      }
      restarted += 1
    })
    paths = current.paths
    write(join(paths.destination, "old.txt"), "old")
    write(join(paths.candidate, "new.txt"), "new")
    write(join(paths.data, "value.txt"), "old-data")

    await expect(current.engine.apply("owner.example", true)).rejects.toThrow("candidate unhealthy")

    expect(text(join(paths.destination, "old.txt"))).toBe("old")
    expect(existsSync(join(paths.destination, "new.txt"))).toBe(false)
    expect(text(join(paths.data, "value.txt"))).toBe("old-data")
    expect(restarted).toBe(1)
    expect(current.stops).toEqual(["owner.example", "owner.example"])
  })

  it("explicitly swaps to known-good code/data and retains the displaced version", async () => {
    let paths!: PluginTransactionPaths
    const current = fixture(async () => {
      expect(text(join(paths.destination, "version.txt"))).toBe("known-good")
      expect(text(join(paths.data, "value.txt"))).toBe("known-good-data")
    })
    paths = current.paths
    write(join(paths.destination, "version.txt"), "current")
    write(join(paths.data, "value.txt"), "current-data")
    write(join(paths.knownGoodCode, "version.txt"), "known-good")
    write(join(paths.knownGoodData, "value.txt"), "known-good-data")

    await current.engine.restoreKnownGood("owner.example")

    expect(text(join(paths.destination, "version.txt"))).toBe("known-good")
    expect(text(join(paths.data, "value.txt"))).toBe("known-good-data")
    expect(text(join(paths.knownGoodCode, "version.txt"))).toBe("current")
    expect(text(join(paths.knownGoodData, "value.txt"))).toBe("current-data")
  })

  it("restores the absence of known-good data and preserves the backup after failure", async () => {
    let shouldFail = false
    const current = fixture(async () => {
      if (shouldFail) throw new Error("known-good unhealthy")
    })
    write(join(current.paths.destination, "version.txt"), "current")
    write(join(current.paths.data, "value.txt"), "current-data")
    write(join(current.paths.knownGoodCode, "version.txt"), "known-good")

    await current.engine.restoreKnownGood("owner.example")
    expect(existsSync(current.paths.data)).toBe(false)
    expect(text(join(current.paths.knownGoodCode, "version.txt"))).toBe("current")

    // Swapping back now fails verification. The current code/data and the
    // still-useful known-good backup both survive the rollback.
    write(join(current.paths.data, "value.txt"), "new-current-data")
    shouldFail = true
    await expect(current.engine.restoreKnownGood("owner.example")).rejects.toThrow(
      "known-good unhealthy"
    )
    expect(text(join(current.paths.destination, "version.txt"))).toBe("known-good")
    expect(text(join(current.paths.data, "value.txt"))).toBe("new-current-data")
    expect(text(join(current.paths.knownGoodCode, "version.txt"))).toBe("current")
  })

  it("rejects restore when no known-good backup exists", async () => {
    const current = fixture(async () => undefined)
    await expect(current.engine.restoreKnownGood("owner.example")).rejects.toThrow(
      "no known-good version"
    )
  })

  it("removes code and data created by a failed first install", async () => {
    let paths!: PluginTransactionPaths
    const current = fixture(async () => {
      write(join(paths.data, "created.txt"), "temporary")
      throw new Error("did not become ready")
    })
    paths = current.paths
    write(join(paths.candidate, "new.txt"), "new")

    await expect(current.engine.apply("owner.example", false)).rejects.toThrow(
      "did not become ready"
    )
    expect(existsSync(paths.destination)).toBe(false)
    expect(existsSync(paths.data)).toBe(false)
  })

  it("reports both the update and rollback failures", async () => {
    const current = fixture(async () => {
      throw new Error("process unavailable")
    })
    write(join(current.paths.destination, "old.txt"), "old")
    write(join(current.paths.candidate, "new.txt"), "new")
    await expect(current.engine.apply("owner.example", true)).rejects.toThrow(
      /update failed \(process unavailable\) and rollback failed \(process unavailable\)/
    )
  })

  it("rolls back interrupted swaps during startup recovery", async () => {
    const current = fixture(async () => undefined)
    write(join(current.paths.destination, "new.txt"), "new")
    write(join(current.paths.codeBackup, "old.txt"), "old")
    write(join(current.paths.data, "value.txt"), "candidate-data")
    write(join(current.paths.dataBackup, "value.txt"), "old-data")
    writeJournal(current.paths, "candidateInstalled")

    await current.engine.recover()

    expect(text(join(current.paths.destination, "old.txt"))).toBe("old")
    expect(text(join(current.paths.data, "value.txt"))).toBe("old-data")
    expect(existsSync(current.paths.journal)).toBe(false)
  })

  it("finishes backup promotion after a verified transaction was interrupted", async () => {
    const current = fixture(async () => undefined)
    write(join(current.paths.destination, "new.txt"), "new")
    write(join(current.paths.codeBackup, "old.txt"), "old")
    write(join(current.paths.data, "value.txt"), "new-data")
    write(join(current.paths.dataBackup, "value.txt"), "old-data")
    writeJournal(current.paths, "verified")

    await current.engine.recover()

    expect(text(join(current.paths.destination, "new.txt"))).toBe("new")
    expect(text(join(current.paths.knownGoodCode, "old.txt"))).toBe("old")
    expect(text(join(current.paths.knownGoodData, "value.txt"))).toBe("old-data")
  })

  it("makes verified recovery idempotent after backups were already promoted", async () => {
    const current = fixture(async () => undefined)
    write(join(current.paths.destination, "new.txt"), "new")
    write(join(current.paths.knownGoodCode, "old.txt"), "old")
    write(join(current.paths.data, "value.txt"), "new-data")
    write(join(current.paths.knownGoodData, "value.txt"), "old-data")
    writeJournal(current.paths, "verified")

    await current.engine.recoverPlugin("owner.example")

    expect(text(join(current.paths.knownGoodCode, "old.txt"))).toBe("old")
    expect(text(join(current.paths.knownGoodData, "value.txt"))).toBe("old-data")
  })

  it("recovers a stopped transaction before any code or data moved", async () => {
    const current = fixture(async () => undefined)
    write(join(current.paths.destination, "old.txt"), "old")
    write(join(current.paths.data, "value.txt"), "old-data")
    write(join(current.paths.candidate, "new.txt"), "new")
    writeJournal(current.paths, "stopped")

    await current.engine.recoverPlugin("owner.example")

    expect(text(join(current.paths.destination, "old.txt"))).toBe("old")
    expect(text(join(current.paths.data, "value.txt"))).toBe("old-data")
    expect(existsSync(current.paths.candidate)).toBe(false)
  })

  it("cleans orphan artifacts with and without current destinations", async () => {
    const promoted = fixture(async () => undefined)
    write(join(promoted.paths.destination, "new.txt"), "new")
    write(join(promoted.paths.codeBackup, "old.txt"), "old")
    write(join(promoted.paths.data, "value.txt"), "new-data")
    write(join(promoted.paths.dataBackup, "value.txt"), "old-data")
    await promoted.engine.recoverPlugin("owner.example")
    expect(text(join(promoted.paths.knownGoodCode, "old.txt"))).toBe("old")
    expect(text(join(promoted.paths.knownGoodData, "value.txt"))).toBe("old-data")

    const restored = fixture(async () => undefined)
    write(join(restored.paths.codeBackup, "old.txt"), "old")
    write(join(restored.paths.dataBackup, "value.txt"), "old-data")
    await restored.engine.recoverPlugin("owner.example")
    expect(text(join(restored.paths.destination, "old.txt"))).toBe("old")
    expect(text(join(restored.paths.data, "value.txt"))).toBe("old-data")
  })

  it("conservatively restores fixed backups when a journal is corrupt", async () => {
    const current = fixture(async () => undefined)
    write(join(current.paths.codeBackup, "old.txt"), "old")
    write(join(current.paths.dataBackup, "value.txt"), "old-data")
    write(current.paths.journal, "not json")

    await current.engine.recoverPlugin("owner.example")

    expect(text(join(current.paths.destination, "old.txt"))).toBe("old")
    expect(text(join(current.paths.data, "value.txt"))).toBe("old-data")
    expect(current.stops).toEqual(["owner.example"])
  })

  it("handles structurally invalid journals without assuming backups exist", async () => {
    const nullJournal = fixture(async () => undefined)
    write(nullJournal.paths.journal, "null")
    await nullJournal.engine.recoverPlugin("owner.example")
    expect(nullJournal.stops).toEqual(["owner.example"])

    const invalidJournal = fixture(async () => undefined)
    write(
      invalidJournal.paths.journal,
      JSON.stringify({ phase: "unknown", pluginId: "owner.example", schemaVersion: 1 })
    )
    await invalidJournal.engine.recoverPlugin("owner.example")
    expect(invalidJournal.stops).toEqual(["owner.example"])
  })

  it("includes non-Error failures when rollback also fails", async () => {
    const current = fixture(async () => Promise.reject("offline"))
    write(join(current.paths.destination, "old.txt"), "old")
    write(join(current.paths.candidate, "new.txt"), "new")
    await expect(current.engine.apply("owner.example", true)).rejects.toThrow(
      /update failed \(offline\) and rollback failed \(offline\)/
    )
  })

  it("serializes operations for one plugin without blocking another plugin", async () => {
    const current = fixture(async () => undefined)
    const order: Array<string> = []
    let releaseFirst = (): void => undefined
    let firstEntered = (): void => undefined
    const entered = new Promise<void>((resolvePromise) => {
      firstEntered = resolvePromise
    })
    const gate = new Promise<void>((resolvePromise) => {
      releaseFirst = resolvePromise
    })
    const first = current.engine.withLock("owner.example", async () => {
      order.push("first:start")
      firstEntered()
      await gate
      order.push("first:end")
    })
    await entered
    const second = current.engine.withLock("owner.example", async () => {
      order.push("second")
    })
    const other = current.engine.withLock("owner.other", async () => {
      order.push("other")
    })
    await other
    expect(order).toEqual(["first:start", "other"])
    releaseFirst()
    await Promise.all([first, second])
    expect(order).toEqual(["first:start", "other", "first:end", "second"])
  })

  it("ignores an absent transaction directory and rejects unsafe ids", async () => {
    const current = fixture(async () => undefined)
    await expect(current.engine.recover()).resolves.toBeUndefined()
    expect(() => current.engine.paths("../unsafe")).toThrow("Invalid plugin transaction id")
  })
})
