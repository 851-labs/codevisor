import { homedir } from "node:os"
import { join } from "node:path"

import { afterEach, describe, expect, it } from "vitest"

import {
  canonicalDatabasePaths,
  codevisorRoot,
  defaultDatabasePath,
  resolveDataDir,
  resolveLogsDir,
  resolveServerDataLayout
} from "./data-dir.js"

const previousDataDir = process.env["CODEVISOR_DATA_DIR"]
const previousLogsDir = process.env["CODEVISOR_LOGS_DIR"]

afterEach(() => {
  if (previousDataDir === undefined) {
    delete process.env["CODEVISOR_DATA_DIR"]
  } else {
    process.env["CODEVISOR_DATA_DIR"] = previousDataDir
  }
  if (previousLogsDir === undefined) {
    delete process.env["CODEVISOR_LOGS_DIR"]
  } else {
    process.env["CODEVISOR_LOGS_DIR"] = previousLogsDir
  }
})

describe("server data layout", () => {
  const root = { platform: "linux", uid: 0, home: "/root", dataDirectory: undefined }
  const canonical = "/root/.codevisor/data/codevisor-server.sqlite"
  const legacy = "/var/lib/codevisor/data/codevisor-server.sqlite"

  it.each([undefined, canonical, legacy])("migrates the Linux root default (%s)", (requested) => {
    expect(resolveServerDataLayout(requested, root)).toEqual({
      databasePath: canonical,
      legacyDataDirectory: "/var/lib/codevisor/data"
    })
  })

  it("leaves macOS and non-root Linux on their home-directory defaults", () => {
    for (const platform of ["darwin", "linux"]) {
      const context = { ...root, platform, uid: 501, home: "/home/person" }
      expect(resolveServerDataLayout(undefined, context)).toEqual({
        databasePath: "/home/person/.codevisor/data/codevisor-server.sqlite"
      })
      expect(resolveServerDataLayout(legacy, context)).toEqual({ databasePath: legacy })
    }
    expect(resolveServerDataLayout(legacy, { ...root, platform: "darwin" })).toEqual({
      databasePath: legacy
    })
  })

  it("honors explicit database and environment overrides without migrating them", () => {
    expect(resolveServerDataLayout("/custom/server.db", root)).toEqual({
      databasePath: "/custom/server.db"
    })
    expect(resolveServerDataLayout(undefined, { ...root, dataDirectory: "/custom/data" })).toEqual({
      databasePath: "/custom/data/codevisor-server.sqlite"
    })
    expect(resolveServerDataLayout(legacy, { ...root, dataDirectory: "/custom/data" })).toEqual({
      databasePath: legacy
    })
  })
})

describe("canonical data directory", () => {
  it("lays out ~/.codevisor identically on every platform", () => {
    delete process.env["CODEVISOR_DATA_DIR"]
    delete process.env["CODEVISOR_LOGS_DIR"]
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

  it("honors the CODEVISOR_LOGS_DIR override", () => {
    process.env["CODEVISOR_LOGS_DIR"] = "/tmp/custom-logs"
    expect(resolveLogsDir()).toBe("/tmp/custom-logs")
  })
})
