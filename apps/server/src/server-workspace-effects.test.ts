import { mkdirSync, mkdtempSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"

import { describe, expect, it, vi } from "vitest"

import { sweepWorktreeXcodeArtifacts } from "./server-workspace-effects.js"
import { tempDirs } from "./test-support.js"

describe("sweepWorktreeXcodeArtifacts", () => {
  it("does nothing off macOS, where there is no Xcode host", async () => {
    await expect(sweepWorktreeXcodeArtifacts(undefined)).resolves.toBeUndefined()
  })

  it("sweeps the worktrees root with the given host", async () => {
    const root = mkdtempSync(join(tmpdir(), "codevisor-xcode-sweep-"))
    tempDirs.push(root)
    const derivedDataRoot = join(root, "DerivedData")
    const simulatorDevicesRoot = join(root, "Devices")
    mkdirSync(derivedDataRoot)
    mkdirSync(simulatorDevicesRoot)
    process.env["CODEVISOR_WORKTREES_ROOT"] = join(root, "worktrees")
    try {
      const simctl = vi.fn(async (_args: ReadonlyArray<string>) => {})
      await expect(
        sweepWorktreeXcodeArtifacts({ derivedDataRoot, simulatorDevicesRoot, simctl })
      ).resolves.toBeUndefined()
    } finally {
      delete process.env["CODEVISOR_WORKTREES_ROOT"]
    }
  })
})
