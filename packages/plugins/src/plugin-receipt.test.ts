import { writeFileSync } from "node:fs"
import { join } from "node:path"
import { describe, expect, it } from "vitest"
import {
  PLUGIN_INSTALL_RECEIPT_FILENAME,
  readPluginInstallReceipt,
  writePluginInstallReceipt,
  type PluginInstallReceipt
} from "./plugin-receipt.js"
import { makeDir } from "./test-support.js"

const receipt = (overrides: Partial<PluginInstallReceipt> = {}): PluginInstallReceipt => ({
  installedAt: "2026-08-23T12:00:00.000Z",
  installedVersion: "1.0.0",
  pluginId: "owner.example",
  resolvedCommit: "0123456789abcdef0123456789abcdef01234567",
  schemaVersion: 1,
  source: {
    kind: "github",
    repo: "owner/example",
    tracking: "registry",
    url: "https://github.com/owner/example.git"
  },
  updatedAt: "2026-08-23T12:00:00.000Z",
  ...overrides
})

describe("plugin install receipts", () => {
  it("writes and reads a valid receipt", async () => {
    const directory = makeDir("codevisor-plugin-receipt-")
    await writePluginInstallReceipt(directory, receipt())
    expect(readPluginInstallReceipt(directory)).toEqual(receipt())
  })

  it("treats missing, malformed, and incomplete receipts as unknown provenance", () => {
    const directory = makeDir("codevisor-plugin-receipt-")
    expect(readPluginInstallReceipt(directory)).toBeUndefined()
    const path = join(directory, PLUGIN_INSTALL_RECEIPT_FILENAME)
    writeFileSync(path, "not json")
    expect(readPluginInstallReceipt(directory)).toBeUndefined()
    writeFileSync(path, JSON.stringify({ schemaVersion: 1, pluginId: "owner.example" }))
    expect(readPluginInstallReceipt(directory)).toBeUndefined()
  })

  it("rejects receipts with invalid dates or source fields", () => {
    const directory = makeDir("codevisor-plugin-receipt-")
    const path = join(directory, PLUGIN_INSTALL_RECEIPT_FILENAME)
    const invalid: ReadonlyArray<unknown> = [
      null,
      receipt({ schemaVersion: 2 as 1 }),
      receipt({ pluginId: "" }),
      receipt({ resolvedCommit: 7 as unknown as string }),
      receipt({ resolvedCommit: "not-a-sha" }),
      receipt({ installedVersion: "" }),
      receipt({ installedAt: 7 as unknown as string }),
      receipt({ installedAt: "" }),
      receipt({ installedAt: "not-a-date" }),
      receipt({ updatedAt: "not-a-date" }),
      receipt({ source: undefined as unknown as PluginInstallReceipt["source"] }),
      receipt({ source: { kind: "invalid" as "git", tracking: "pinned", url: "git:x" } }),
      receipt({ source: { kind: "git", tracking: "pinned", url: "" } }),
      receipt({
        source: { kind: "git", tracking: "invalid" as "pinned", url: "git:x" }
      }),
      receipt({
        source: { kind: "git", repo: "", tracking: "pinned", url: "git:x" }
      }),
      receipt({
        source: { kind: "git", requestedRef: "", tracking: "pinned", url: "git:x" }
      }),
      receipt({
        source: { kind: "git", subpath: "", tracking: "pinned", url: "git:x" }
      })
    ]
    for (const candidate of invalid) {
      writeFileSync(path, JSON.stringify(candidate))
      expect(readPluginInstallReceipt(directory), JSON.stringify(candidate)).toBeUndefined()
    }

    for (const kind of ["git", "local"] as const) {
      const valid = receipt({ source: { kind, tracking: "pinned", url: `${kind}:source` } })
      writeFileSync(path, JSON.stringify(valid))
      expect(readPluginInstallReceipt(directory)).toEqual(valid)
    }
  })
})
