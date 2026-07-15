import { homedir } from "node:os"
import { join } from "node:path"
import { afterEach, describe, expect, it } from "vitest"
import {
  canonicalDatabasePaths,
  codevisorRoot,
  defaultDatabasePath,
  resolveDataDir,
  resolveLogsDir
} from "./data-dir.js"

const previousDataDir = process.env["CODEVISOR_DATA_DIR"]

afterEach(() => {
  if (previousDataDir === undefined) {
    delete process.env["CODEVISOR_DATA_DIR"]
  } else {
    process.env["CODEVISOR_DATA_DIR"] = previousDataDir
  }
})

describe("canonical data directory", () => {
  it("lays out ~/.codevisor identically on every platform", () => {
    delete process.env["CODEVISOR_DATA_DIR"]
    expect(codevisorRoot()).toBe(join(homedir(), ".codevisor"))
    expect(resolveDataDir()).toBe(join(homedir(), ".codevisor", "data"))
    expect(resolveLogsDir()).toBe(join(homedir(), ".codevisor", "logs"))
    expect(defaultDatabasePath()).toBe(
      join(homedir(), ".codevisor", "data", "codevisor-server.sqlite")
    )
    expect(canonicalDatabasePaths()).toContain(defaultDatabasePath())
    expect(canonicalDatabasePaths()).toContain("/var/lib/codevisor/data/codevisor-server.sqlite")
  })

  it("honors the CODEVISOR_DATA_DIR override", () => {
    process.env["CODEVISOR_DATA_DIR"] = "/tmp/custom-data"
    expect(resolveDataDir()).toBe("/tmp/custom-data")
    expect(defaultDatabasePath()).toBe("/tmp/custom-data/codevisor-server.sqlite")
  })
})
