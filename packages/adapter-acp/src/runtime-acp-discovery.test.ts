import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"

import {
  harnessCatalog,
  locateExecutableOnPath,
  makeAgentRuntime,
  OPENCODE_INSTALL_PATH
} from "@codevisor/agent-runtime"
import { describe, expect, it } from "vitest"

import { makeAcpProvider } from "./index.js"
import { makeAcpAgentRuntime, makeConnector, run } from "./test-support.js"

describe("@codevisor/agent-runtime", () => {
  it("launches directly ACP-capable harnesses from the user's installation", () => {
    const directlyCapable = harnessCatalog.filter((harness) => harness.provider === "acp")
    expect(directlyCapable.some((harness) => harness.launch?.kind === "npx")).toBe(false)
  })

  it("requires an adapter's underlying CLI before reporting it ready", async () => {
    const runtime = makeAcpAgentRuntime({
      env: { PATH: "/bin" },
      executableExists: (name) => name === "amp-acp" || name === "autohand-acp",
      locateExecutable: () => undefined
    })
    const harnesses = await run(runtime.discoverHarnesses)
    expect(harnesses.find((h) => h.id === "amp")?.readiness).toEqual({
      state: "unavailable",
      detail: "Requires amp"
    })
    expect(harnesses.find((h) => h.id === "autohand")?.readiness).toEqual({
      state: "unavailable",
      detail: "Requires autohand"
    })
  })

  it("discovers ready local executables and unavailable harnesses", async () => {
    const runtime = makeAcpAgentRuntime({
      env: { PATH: "/bin" },
      executableExists: (name) => ["gemini", "goose", "codex", "cursor-agent"].includes(name),
      locateExecutable: () => undefined
    })

    const harnesses = await run(runtime.discoverHarnesses)
    expect(harnesses.find((harness) => harness.id === "gemini")?.readiness).toEqual({
      state: "ready"
    })
    expect(harnesses.find((harness) => harness.id === "codex")?.readiness).toEqual({
      state: "ready"
    })
    expect(harnesses.find((harness) => harness.id === "goose")?.readiness).toEqual({
      state: "ready"
    })
    expect(harnesses.find((harness) => harness.id === "claude-code")?.readiness.detail).toBe(
      "CLI not found on PATH"
    )
    expect(harnesses.find((harness) => harness.id === "factory-droid")?.launchKind).toBe(
      "executable"
    )
    expect(harnesses.find((harness) => harness.id === "cursor")?.readiness).toEqual({
      detail: "Provider not available",
      state: "unavailable"
    })
    expect(harnesses.find((harness) => harness.id === "claude-code")?.installHint).toContain(
      "claude.ai/install.sh"
    )
    expect(harnesses.find((harness) => harness.id === "pi")?.installHint).toBe(
      "npm install -g @earendil-works/pi-coding-agent"
    )
    expect(harnesses.find((harness) => harness.id === "gemini")?.installHint).toBeUndefined()
  })

  it("enriches ready harnesses with the resolved path and probed version", async () => {
    const runtime = makeAcpAgentRuntime({
      env: { PATH: "/opt/tools" },
      locateExecutable: (name) => (name === "claude" ? "/opt/tools/claude" : undefined),
      readVersionOutput: (path) =>
        path === "/opt/tools/claude"
          ? Promise.resolve("claude 2.1.5 (Claude Code)")
          : Promise.reject(new Error("unexpected probe"))
    })

    const first = await run(runtime.discoverHarnesses)
    const claudeBefore = first.find((harness) => harness.id === "claude-code")
    expect(claudeBefore?.readiness).toMatchObject({ state: "ready", path: "/opt/tools/claude" })
    expect(claudeBefore?.readiness.version).toBeUndefined()

    await run(runtime.refreshEnvironment)
    const after = await run(runtime.discoverHarnesses)
    expect(after.find((harness) => harness.id === "claude-code")?.readiness).toEqual({
      state: "ready",
      path: "/opt/tools/claude",
      version: "2.1.5"
    })
    expect(after.find((harness) => harness.id === "codex")?.readiness.path).toBeUndefined()
  })

  it("re-probes only the requested harnesses' binaries on a forced version refresh", async () => {
    const versions = new Map([
      ["/opt/tools/claude", "2.1.5"],
      ["/opt/tools/codex", "0.40.0"]
    ])
    const probed: Array<string> = []
    const runtime = makeAcpAgentRuntime({
      env: { PATH: "/opt/tools" },
      locateExecutable: (name) =>
        name === "claude" || name === "codex" ? `/opt/tools/${name}` : undefined,
      readVersionOutput: (path) => {
        probed.push(path)
        return Promise.resolve(`tool ${versions.get(path)}`)
      }
    })
    const versionOf = async (id: string) =>
      (await run(runtime.discoverHarnesses)).find((harness) => harness.id === id)?.readiness.version

    await run(runtime.refreshEnvironment)
    versions.set("/opt/tools/claude", "2.1.6")
    versions.set("/opt/tools/codex", "0.41.0")
    await run(runtime.refreshEnvironment)
    expect(await versionOf("claude-code")).toBe("2.1.5")

    probed.length = 0
    await run(runtime.refreshHarnessVersions(["claude-code"]))
    expect(probed).toEqual(["/opt/tools/claude"])
    expect(await versionOf("claude-code")).toBe("2.1.6")
    expect(await versionOf("codex")).toBe("0.40.0")
  })

  it("skips requested harnesses whose binary isn't installed on a forced version refresh", async () => {
    const probed: Array<string> = []
    const runtime = makeAcpAgentRuntime({
      env: { PATH: "/opt/tools" },
      locateExecutable: (name) => (name === "claude" ? "/opt/tools/claude" : undefined),
      readVersionOutput: (path) => {
        probed.push(path)
        return Promise.resolve("tool 2.1.5")
      }
    })

    await run(runtime.refreshHarnessVersions(["claude-code", "codex"]))

    expect(probed).toEqual(["/opt/tools/claude"])
  })

  it("refreshes the environment so readiness picks up newly installed CLIs", async () => {
    let resolveCalls = 0
    const runtime = makeAcpAgentRuntime({
      env: { PATH: "/before" },
      executableExists: (name, env) => name === "claude" && env.PATH === "/after",
      locateExecutable: () => undefined,
      resolveEnv: () => {
        resolveCalls += 1
        return Promise.resolve({ PATH: "/after" })
      }
    })

    const before = await run(runtime.discoverHarnesses)
    expect(before.find((harness) => harness.id === "claude-code")?.readiness.state).toBe(
      "unavailable"
    )

    await Promise.all([run(runtime.refreshEnvironment), run(runtime.refreshEnvironment)])
    expect(resolveCalls).toBe(1)

    const after = await run(runtime.discoverHarnesses)
    expect(after.find((harness) => harness.id === "claude-code")?.readiness).toEqual({
      state: "ready"
    })

    await run(runtime.refreshEnvironment)
    expect(resolveCalls).toBe(2)
  })

  it("finds a harness where its installer put it when the login shell's PATH misses it", async () => {
    const connector = makeConnector()
    const installed = "/home/me/.opencode/bin/opencode"
    const locate = (name: string) => (name === OPENCODE_INSTALL_PATH ? installed : undefined)
    const runtime = makeAgentRuntime({
      env: { PATH: "/bin", HOME: "/home/me" },
      executableExists: (name) => locate(name) !== undefined,
      locateExecutable: locate,
      providerFactories: [(env) => makeAcpProvider(env, { connector, providerId: "opencode" })]
    })

    const harnesses = await run(runtime.discoverHarnesses)
    expect(harnesses.find((harness) => harness.id === "opencode")?.readiness.state).toBe("ready")
    await run(runtime.createAgentSession("opencode", "/tmp/project", () => Promise.resolve()))
    expect(connector.requests[0]).toMatchObject({ command: installed, args: ["acp"] })
  })

  it("propagates resolveEnv failures as runtime errors and recovers", async () => {
    let attempts = 0
    const runtime = makeAcpAgentRuntime({
      env: { PATH: "/before" },
      executableExists: (name, env) => name === "claude" && env.PATH === "/after",
      resolveEnv: () => {
        attempts += 1
        return attempts === 1
          ? Promise.reject(new Error("shell exploded"))
          : Promise.resolve({ PATH: "/after" })
      }
    })

    await expect(run(runtime.refreshEnvironment)).rejects.toMatchObject({
      operation: "refreshEnvironment"
    })
    await run(runtime.refreshEnvironment)
    const harnesses = await run(runtime.discoverHarnesses)
    expect(harnesses.find((harness) => harness.id === "claude-code")?.readiness.state).toBe("ready")
  })

  it("reports every harness unavailable when no adapters are registered", async () => {
    const runtime = makeAgentRuntime({ env: {}, locateExecutable: () => undefined })
    const harnesses = await run(runtime.discoverHarnesses)
    expect(harnesses.every((harness) => harness.readiness.state === "unavailable")).toBe(true)
  })

  it("checks both ChatGPT.app and Codex.app for the bundled Codex CLI", () => {
    const codex = harnessCatalog.find((harness) => harness.id === "codex")

    expect(codex?.fallbackPaths).toEqual(
      expect.arrayContaining([
        "/Applications/ChatGPT.app/Contents/Resources/codex",
        "~/Applications/ChatGPT.app/Contents/Resources/codex",
        "/Applications/Codex.app/Contents/Resources/codex",
        "~/Applications/Codex.app/Contents/Resources/codex"
      ])
    )
  })

  it("locates absolute and ~-prefixed fallback candidates directly", () => {
    const home = mkdtempSync(join(tmpdir(), "codevisor-locate-"))
    const bundled = join(home, "Applications", "Codex.app", "Contents", "Resources")
    mkdirSync(bundled, { recursive: true })
    const binary = join(bundled, "codex")
    writeFileSync(binary, "#!/bin/sh\n", { mode: 0o755 })
    try {
      expect(locateExecutableOnPath(binary, {})).toBe(binary)
      expect(locateExecutableOnPath(join(home, "missing"), {})).toBeUndefined()
      expect(
        locateExecutableOnPath("~/Applications/Codex.app/Contents/Resources/codex", {
          HOME: home
        })
      ).toBe(binary)
      expect(
        locateExecutableOnPath("~/Applications/Codex.app/Contents/Resources/codex", {})
      ).toBeUndefined()
      expect(locateExecutableOnPath("codex", { PATH: bundled })).toBe(binary)
      expect(locateExecutableOnPath("codex", {})).toBeUndefined()
    } finally {
      rmSync(home, { force: true, recursive: true })
    }
  })
})
