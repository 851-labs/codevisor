import { Effect } from "effect"
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { describe, expect, it } from "vitest"
import { AgentRuntime, harnessCatalog, locateExecutableOnPath } from "@codevisor/agent-runtime"
import { makeAcpAgentRuntime, run } from "./test-support.js"

describe("@codevisor/agent-runtime", () => {
  it("launches directly ACP-capable harnesses from the user's installation", () => {
    const directlyCapable = harnessCatalog.filter(
      (harness) => harness.provider === "acp" && harness.id !== "pi"
    )
    expect(directlyCapable.some((harness) => harness.launch?.kind === "npx")).toBe(false)
  })

  it("discovers ready local executables and unavailable harnesses", async () => {
    const runtime = makeAcpAgentRuntime({
      env: { PATH: "/bin" },
      executableExists: (name) => ["gemini", "opencode", "codex", "cursor-agent"].includes(name),
      // Pinned so path/version enrichment stays off regardless of what is
      // installed on the machine running the tests (e.g. ChatGPT.app).
      locateExecutable: () => undefined,
      // Exercises the background-terminal threading into every provider.
      backgroundTerminals: {
        registry: { register: () => ({ exit: () => {}, output: () => {}, remove: () => {} }) }
      }
    })

    const harnesses = await run(runtime.discoverHarnesses)
    expect(harnesses.find((harness) => harness.id === "gemini")?.readiness).toEqual({
      state: "ready"
    })
    // Every catalog entry now launches the user's installed binary directly.
    expect(harnesses.find((harness) => harness.id === "codex")?.readiness).toEqual({
      state: "ready"
    })
    expect(harnesses.find((harness) => harness.id === "opencode")?.readiness).toEqual({
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
    // Install hints ride along only for harnesses that define them.
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

    // Discovery resolves the path synchronously; versions only exist once a
    // refresh has probed them.
    const first = await run(runtime.discoverHarnesses)
    const claudeBefore = first.find((harness) => harness.id === "claude-code")
    expect(claudeBefore?.readiness).toMatchObject({ state: "ready", path: "/opt/tools/claude" })
    expect(claudeBefore?.readiness.version).toBeUndefined()

    // A refresh (the client's "Detect again") awaits probes even without an
    // env resolver, so the next discovery carries the version.
    await run(runtime.refreshEnvironment)
    const after = await run(runtime.discoverHarnesses)
    expect(after.find((harness) => harness.id === "claude-code")?.readiness).toEqual({
      state: "ready",
      path: "/opt/tools/claude",
      version: "2.1.5"
    })
    // Unavailable harnesses stay unenriched.
    expect(after.find((harness) => harness.id === "codex")?.readiness.path).toBeUndefined()
  })

  it("refreshes the environment so readiness picks up newly installed CLIs", async () => {
    let resolveCalls = 0
    const runtime = makeAcpAgentRuntime({
      env: { PATH: "/before" },
      // Readiness is keyed off the live env's PATH: claude "installs" only
      // after refreshEnvironment swaps the env.
      executableExists: (name, env) => name === "claude" && env.PATH === "/after",
      // Pinned: the refresh's version probe must not locate (and spawn) real
      // binaries installed on the machine running the tests.
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

    // Concurrent refreshes share a single in-flight resolution.
    await Promise.all([run(runtime.refreshEnvironment), run(runtime.refreshEnvironment)])
    expect(resolveCalls).toBe(1)

    const after = await run(runtime.discoverHarnesses)
    expect(after.find((harness) => harness.id === "claude-code")?.readiness).toEqual({
      state: "ready"
    })

    // A later refresh starts a fresh resolution (the shared promise clears).
    await run(runtime.refreshEnvironment)
    expect(resolveCalls).toBe(2)
  })

  it("treats refreshEnvironment as a no-op without a resolveEnv", async () => {
    const runtime = makeAcpAgentRuntime({ env: { PATH: "/fixed" } })
    await expect(run(runtime.refreshEnvironment)).resolves.toBeUndefined()
  })

  it("merges injected extra harnesses and tags them as custom", async () => {
    const runtime = makeAcpAgentRuntime({
      env: { PATH: "/bin" },
      executableExists: (name) => name === "my-agent",
      locateExecutable: () => undefined,
      extraHarnesses: [
        {
          detectBinaries: ["my-agent"],
          id: "my-agent",
          launch: { args: ["acp"], command: "my-agent", kind: "executable" },
          name: "My Agent",
          provider: "acp",
          symbolName: "terminal"
        }
      ]
    })

    // The effective catalog is builtins + the extra entry, and is exposed on
    // the service for consumers (harness auth, lifecycle).
    expect(runtime.catalog).toHaveLength(harnessCatalog.length + 1)
    expect(runtime.catalog.find((definition) => definition.id === "my-agent")?.name).toBe(
      "My Agent"
    )

    const harnesses = await run(runtime.discoverHarnesses)
    const custom = harnesses.find((harness) => harness.id === "my-agent")
    expect(custom).toMatchObject({
      name: "My Agent",
      launchKind: "executable",
      source: "custom",
      readiness: { state: "ready" }
    })
    // Builtins keep their registry source.
    expect(harnesses.find((harness) => harness.id === "codex")?.source).toBe("registry")
  })

  it("reports disabled custom harnesses as unavailable and refuses their sessions", async () => {
    const runtime = makeAcpAgentRuntime({
      env: { PATH: "/bin" },
      extraHarnesses: [
        {
          detectBinaries: ["paused-agent"],
          disabledReason: "Temporarily paused",
          id: "paused-agent",
          launch: { args: ["acp"], command: "paused-agent", kind: "executable" },
          name: "Paused Agent",
          provider: "acp",
          symbolName: "terminal"
        }
      ]
    })

    const harnesses = await run(runtime.discoverHarnesses)
    expect(harnesses.find((harness) => harness.id === "paused-agent")?.readiness).toEqual({
      detail: "Temporarily paused",
      state: "unavailable"
    })
    await expect(
      run(runtime.createAgentSession("paused-agent", "/tmp/project", () => undefined))
    ).rejects.toThrow("Paused Agent is unavailable: Temporarily paused")
  })

  it("drops extra harnesses whose id collides with a builtin", async () => {
    const runtime = makeAcpAgentRuntime({
      env: { PATH: "/bin" },
      executableExists: () => false,
      locateExecutable: () => undefined,
      extraHarnesses: [
        {
          detectBinaries: ["fake-codex"],
          id: "codex",
          launch: { args: [], command: "fake-codex", kind: "executable" },
          name: "Fake Codex",
          provider: "acp",
          symbolName: "terminal"
        }
      ]
    })

    expect(runtime.catalog).toHaveLength(harnessCatalog.length)
    const harnesses = await run(runtime.discoverHarnesses)
    const codex = harnesses.find((harness) => harness.id === "codex")
    expect(codex?.name).toBe("Codex")
    expect(codex?.source).toBe("registry")
  })

  it("keeps the builtin catalog identity when no extras are injected", () => {
    const runtime = makeAcpAgentRuntime({ env: { PATH: "/bin" } })
    expect(runtime.catalog).toBe(harnessCatalog)
  })

  it("swaps custom entries live via setExtraHarnesses", async () => {
    const runtime = makeAcpAgentRuntime({
      env: { PATH: "/bin" },
      executableExists: () => false,
      locateExecutable: () => undefined
    })
    expect(runtime.catalog).toBe(harnessCatalog)

    runtime.setExtraHarnesses([
      {
        detectBinaries: ["late-agent"],
        id: "late-agent",
        launch: { args: ["acp"], command: "late-agent", kind: "executable" },
        name: "Late Agent",
        provider: "acp",
        symbolName: "terminal"
      }
    ])
    expect(runtime.catalog).toHaveLength(harnessCatalog.length + 1)
    const harnesses = await run(runtime.discoverHarnesses)
    expect(harnesses.find((harness) => harness.id === "late-agent")?.source).toBe("custom")

    runtime.setExtraHarnesses([])
    expect(runtime.catalog).toBe(harnessCatalog)
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
    // The failed in-flight promise clears; the next refresh succeeds.
    await run(runtime.refreshEnvironment)
    const harnesses = await run(runtime.discoverHarnesses)
    expect(harnesses.find((harness) => harness.id === "claude-code")?.readiness.state).toBe("ready")
  })

  it("constructs the Effect service layer and handles missing PATH", async () => {
    await expect(run(makeAcpAgentRuntime().discoverHarnesses)).resolves.toEqual(expect.any(Array))

    // locateExecutable is pinned to "nothing found": the default locator also
    // probes absolute fallbackPaths (e.g. /Applications/Codex.app), which
    // would make this machine-dependent.
    const layeredHarnesses = await run(
      Effect.gen(function* () {
        const runtime = yield* AgentRuntime
        return yield* runtime.discoverHarnesses
      }).pipe(Effect.provide(AgentRuntime.layer({ env: {}, locateExecutable: () => undefined })))
    )
    expect(layeredHarnesses.every((harness) => harness.readiness.state === "unavailable")).toBe(
      true
    )

    const runtime = makeAcpAgentRuntime({ env: {}, locateExecutable: () => undefined })
    expect((await run(runtime.discoverHarnesses))[0]?.readiness.detail).toBe(
      "CLI not found on PATH"
    )
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
      // Absolute candidates skip PATH entirely.
      expect(locateExecutableOnPath(binary, {})).toBe(binary)
      expect(locateExecutableOnPath(join(home, "missing"), {})).toBeUndefined()
      // `~/` expands via env.HOME; without a HOME there is nothing to probe.
      expect(
        locateExecutableOnPath("~/Applications/Codex.app/Contents/Resources/codex", {
          HOME: home
        })
      ).toBe(binary)
      expect(
        locateExecutableOnPath("~/Applications/Codex.app/Contents/Resources/codex", {})
      ).toBeUndefined()
      // Plain names still walk PATH — and tolerate an absent PATH.
      expect(locateExecutableOnPath("codex", { PATH: bundled })).toBe(binary)
      expect(locateExecutableOnPath("codex", {})).toBeUndefined()
    } finally {
      rmSync(home, { force: true, recursive: true })
    }
  })
})
