import { describe, expect, it } from "vitest"
import { basename, dirname } from "node:path"
import {
  assertGitAvailable,
  assertPluginRequirements,
  findExecutableOnPath
} from "./plugin-requirements.js"
import { exampleManifest } from "./test-support.js"

const v2Manifest = {
  ...exampleManifest,
  minCodevisorVersion: "1.4.0",
  protocolVersion: 2 as const,
  requirements: {
    executables: [
      {
        helpUrl: "https://nodejs.org/",
        installHint: "Install Node.js 22 or newer.",
        name: "node"
      }
    ]
  },
  run: { argv: ["node", "server.js"] }
}

describe("plugin requirements", () => {
  it("resolves executables from the supplied PATH and reports misses", async () => {
    expect(
      await findExecutableOnPath(basename(process.execPath), { PATH: dirname(process.execPath) })
    ).toBe(process.execPath)
    expect(await findExecutableOnPath("definitely-not-codevisor", { PATH: "/nonexistent" })).toBe(
      undefined
    )

    const previousPath = process.env["PATH"]
    delete process.env["PATH"]
    try {
      expect(await findExecutableOnPath("definitely-not-codevisor", {})).toBeUndefined()
    } finally {
      if (previousPath !== undefined) process.env["PATH"] = previousPath
    }
  })

  it("accepts a compatible server with every executable", async () => {
    await expect(
      assertPluginRequirements({
        codevisorVersion: "1.5.0",
        env: {},
        findExecutable: async (name) => `/bin/${name}`,
        manifest: v2Manifest,
        platform: "darwin"
      })
    ).resolves.toBeUndefined()
  })

  it("reports platform and Codevisor incompatibility before setup", async () => {
    await expect(
      assertPluginRequirements({ env: {}, manifest: v2Manifest, platform: "linux" })
    ).rejects.toThrow(/development build has no version metadata/)
    await expect(
      assertPluginRequirements({
        codevisorVersion: "1.3.9",
        env: {},
        manifest: { ...v2Manifest, platforms: ["darwin"] },
        platform: "darwin"
      })
    ).rejects.toThrow(/requires Codevisor 1.4.0 or newer/)
    await expect(
      assertPluginRequirements({
        codevisorVersion: "1.5.0",
        env: {},
        manifest: { ...v2Manifest, platforms: ["linux"] },
        platform: "darwin"
      })
    ).rejects.toThrow(/does not support darwin/)
  })

  it("reports a missing executable with author guidance", async () => {
    await expect(
      assertPluginRequirements({
        codevisorVersion: "1.5.0",
        env: {},
        findExecutable: async () => undefined,
        manifest: v2Manifest,
        platform: "darwin"
      })
    ).rejects.toThrow(/requires `node`.*Install Node\.js 22 or newer.*https:\/\/nodejs\.org\//)
    await expect(
      assertPluginRequirements({
        codevisorVersion: "1.5.0",
        env: {},
        findExecutable: async () => undefined,
        manifest: {
          ...v2Manifest,
          minCodevisorVersion: undefined,
          requirements: { executables: [{ name: "node" }] }
        },
        platform: "darwin"
      })
    ).rejects.toThrow(/could not find it on PATH\.$/)
  })

  it("accepts protocol v2 manifests with no optional requirements", async () => {
    await expect(
      assertPluginRequirements({
        codevisorVersion: "1.5.0",
        env: {},
        manifest: {
          ...v2Manifest,
          minCodevisorVersion: undefined,
          requirements: undefined
        },
        platform: "darwin"
      })
    ).resolves.toBeUndefined()
  })

  it("gives a concrete Git installation error", async () => {
    await expect(assertGitAvailable({}, async () => undefined)).rejects.toThrow(
      /xcode-select --install/
    )
  })
})
