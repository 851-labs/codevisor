import { describe, expect, it } from "vitest"
import type { HarnessDefinition, ProviderEnvironment } from "@codevisor/agent-runtime"
import type { CodexSpawnRequest } from "./client.js"
import { makeCodexProvider } from "./provider.js"
import { definition, environment, FakeCodexClient, run, setup } from "./test-support.js"

describe("CodexProvider", () => {
  it("prefers app-server thread names while retaining scanner fallbacks", async () => {
    const client = new FakeCodexClient()
    client.listedThreads = [
      { id: "one", name: "Named by Codex", preview: "First prompt one" },
      { id: "two", name: null, preview: "" }
    ]
    const provider = makeCodexProvider(environment, {
      connector: async () => client,
      scanAgentSessions: async () => [
        { cwd: "/one", sessionId: "one", title: "Scanner one" },
        { cwd: "/two", sessionId: "two", title: "Scanner two" }
      ]
    })

    await expect(provider.listAgentSessions!(definition)).resolves.toEqual([
      { cwd: "/one", sessionId: "one", title: "Named by Codex" },
      { cwd: "/two", sessionId: "two", title: "Scanner two" }
    ])
    expect(client.closed).toBe(true)
  })

  it("handshakes, starts a thread, and reports config options", async () => {
    const { client, created, spawns } = await setup()
    expect(spawns[0]).toMatchObject({ command: "/bin/codex", cwd: "/tmp/project" })
    expect(client.requests.map((request) => request.method)).toEqual([
      "initialize",
      "thread/start",
      "model/list"
    ])
    expect(client.notifications).toEqual([{ method: "initialized", params: undefined }])
    expect(created?.metadata.sessionId).toBe("thread-new")
    const options = created?.metadata.configOptions ?? []
    const modelOption = options.find((option) => option.id === "model")
    expect(modelOption?.currentValue).toBe("gpt-5.2-codex")
    // Full catalog minus hidden models.
    expect(modelOption?.options.map((option) => ("value" in option ? option.value : ""))).toEqual([
      "gpt-5.2-codex",
      "gpt-5.5"
    ])
    // Efforts come from the current model's capabilities, defaulted per model.
    const effortOption = options.find((option) => option.id === "effort")
    expect(effortOption?.currentValue).toBe("medium")
    expect(effortOption?.options.map((option) => ("value" in option ? option.value : ""))).toEqual([
      "low",
      "medium",
      "xhigh"
    ])
    // Approval/sandbox presets are exposed as session modes; full access is
    // the default posture.
    expect(created?.metadata.modes?.currentModeId).toBe("agent-full-access")
    expect(created?.metadata.modes?.availableModes.map((mode) => mode.id)).toEqual([
      "plan",
      "read-only",
      "agent",
      "agent-full-access"
    ])
    expect(created?.metadata.modes?.availableModes.map((mode) => mode.canonicalId)).toEqual([
      "plan",
      "readOnly",
      "ask",
      "fullAccess"
    ])
    // Experimental APIs (collaborationMode, requestUserInput) are opted into
    // at initialize.
    expect(client.requests[0]).toMatchObject({
      method: "initialize",
      params: { capabilities: { experimentalApi: true } }
    })
  })

  it("reports readiness from binary presence", () => {
    const provider = makeCodexProvider(environment)
    expect(provider.readiness(definition)).toEqual({ state: "ready" })
    const missing = makeCodexProvider({
      env: {},
      executableExists: () => false,
      locateExecutable: () => undefined
    })
    expect(missing.readiness(definition)).toEqual({
      detail: "CLI not found on PATH",
      state: "unavailable"
    })
  })

  it("uses the Codex.app bundled binary when it is newer than the PATH CLI", async () => {
    const cli = "/bin/codex"
    const bundled = "/Applications/Codex.app/Contents/Resources/codex"
    const withFallback: HarnessDefinition = { ...definition, fallbackPaths: [bundled] }
    const installed: ProviderEnvironment = {
      env: { PATH: "/bin" },
      executableExists: (name) => name === "codex" || name === bundled,
      locateExecutable: (name) => (name === "codex" ? cli : name === bundled ? bundled : undefined)
    }
    const client = new FakeCodexClient()
    const spawns: Array<CodexSpawnRequest> = []
    const provider = makeCodexProvider(installed, {
      connector: async (request) => {
        spawns.push(request)
        return client
      },
      versionReader: (command) =>
        command === cli
          ? "codex-cli 0.143.0"
          : command === bundled
            ? "codex-cli 0.144.0"
            : undefined
    })

    await run(provider.createSession(withFallback, "/tmp/project", async () => {}))

    expect(spawns[0]).toMatchObject({ command: bundled, cwd: "/tmp/project" })
  })

  it("keeps the PATH Codex CLI when the app bundle is not newer", async () => {
    const cli = "/bin/codex"
    const bundled = "/Applications/Codex.app/Contents/Resources/codex"
    const withFallback: HarnessDefinition = { ...definition, fallbackPaths: [bundled] }
    const installed: ProviderEnvironment = {
      env: { PATH: "/bin" },
      executableExists: (name) => name === "codex" || name === bundled,
      locateExecutable: (name) => (name === "codex" ? cli : name === bundled ? bundled : undefined)
    }
    const client = new FakeCodexClient()
    const spawns: Array<CodexSpawnRequest> = []
    const provider = makeCodexProvider(installed, {
      connector: async (request) => {
        spawns.push(request)
        return client
      },
      versionReader: (command) =>
        command === cli
          ? "codex-cli 0.144.0"
          : command === bundled
            ? "codex-cli 0.144.0"
            : undefined
    })

    await run(provider.createSession(withFallback, "/tmp/project", async () => {}))

    expect(spawns[0]).toMatchObject({ command: cli, cwd: "/tmp/project" })
  })

  it("falls back to the Codex.app bundled binary when the CLI is not on PATH", async () => {
    const bundled = "/Applications/Codex.app/Contents/Resources/codex"
    const appOnly: ProviderEnvironment = {
      env: { PATH: "/bin" },
      executableExists: (name) => name === bundled,
      locateExecutable: (name) => (name === bundled ? bundled : undefined)
    }
    const withFallback: HarnessDefinition = { ...definition, fallbackPaths: [bundled] }

    // Readiness sees the bundled binary even though PATH has nothing.
    const provider = makeCodexProvider(appOnly)
    expect(provider.readiness(withFallback)).toEqual({ state: "ready" })
    expect(provider.readiness(definition)).toEqual({
      detail: "CLI not found on PATH",
      state: "unavailable"
    })

    // Sessions spawn the bundled binary.
    const client = new FakeCodexClient()
    const spawns: Array<CodexSpawnRequest> = []
    const spawning = makeCodexProvider(appOnly, {
      connector: async (request) => {
        spawns.push(request)
        return client
      }
    })
    await run(spawning.createSession(withFallback, "/tmp/project", async () => {}))
    expect(spawns[0]).toMatchObject({ command: bundled, cwd: "/tmp/project" })

    // Neither PATH nor a bundle: session creation fails with a clear error.
    await expect(
      run(spawning.createSession(definition, "/tmp/project", async () => {}))
    ).rejects.toThrow("codex not found on PATH or in the Codex app")
  })
})
