import { mkdtemp, readFile, rm } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"

import { describe, expect, it, vi } from "vitest"

import { AGY_GEMINI_DIR_ENV } from "./auth.js"
import { SIGN_IN_DETAIL } from "./protocol.js"
import { makeAntigravityProvider, type AntigravityProviderConfig } from "./provider.js"
import {
  CONVERSATION,
  definition,
  environment,
  fakeConnector,
  fakeRunner,
  recorder,
  run,
  type FakeAgyProcess
} from "./test-support.js"

const managed = {
  id: "acct-1",
  profileKind: "managed" as const,
  env: { [AGY_GEMINI_DIR_ENV]: "/p/gemini" }
}

const provider = (
  config: Partial<AntigravityProviderConfig> & {
    answers?: Parameters<typeof fakeRunner>[0]
    opens?: (process: FakeAgyProcess, index: number) => void
  } = {}
) => {
  const agy = fakeConnector(config.opens)
  const commands = fakeRunner(config.answers)
  return {
    agy,
    commands,
    provider: makeAntigravityProvider(environment, {
      connector: agy.connector,
      runner: commands.runner,
      ...config
    })
  }
}

describe("Antigravity provider", () => {
  it("is ready once agy is on PATH", () => {
    const { provider: ready } = provider()
    expect(ready.readiness(definition)).toEqual({ state: "ready" })
    const missing = makeAntigravityProvider({ ...environment, locateExecutable: () => undefined })
    expect(missing.readiness(definition)).toEqual({
      state: "unavailable",
      detail: "CLI not found on PATH"
    })
    return expect(run(missing.createSession(definition, "/repo", recorder().emit))).rejects.toThrow(
      "agy not found on PATH"
    )
  })

  it("starts a chat on the account's own data root with the listed models", async () => {
    const { agy, commands, provider: antigravity } = provider()
    const created = await run(
      antigravity.createSession(definition, "/repo", recorder().emit, managed)
    )
    expect(created.metadata.sessionId).toBe(CONVERSATION)
    expect(created.metadata.configOptions.map((option) => option.currentValue)).toEqual([
      "gemini-4-argon",
      "medium"
    ])
    expect(commands.calls.map((call) => call.args)).toEqual([
      ["--version"],
      ["--gemini_dir=/p/gemini", "models"]
    ])
    expect(commands.calls[1]).toMatchObject({
      cwd: "/home/me",
      env: { SSH_CLIENT: "127.0.0.1 0 0", AGY_CLI_DISABLE_AUTO_UPDATE: "true" }
    })
    expect(agy.processes[0]!.request.args).toEqual(
      expect.arrayContaining(["--model", "gemini-4-argon-medium", "--gemini_dir=/p/gemini"])
    )
    expect(agy.processes[0]!.request.env).not.toHaveProperty(AGY_GEMINI_DIR_ENV)
  })

  it("hands each chat Codevisor's gateway through agy's MCP config", async () => {
    const root = await mkdtemp(join(tmpdir(), "agy-provider-"))
    try {
      const agy = fakeConnector()
      const antigravity = makeAntigravityProvider(
        { ...environment, env: { ...environment.env, HOME: join(root, "home") } },
        {
          connector: agy.connector,
          runner: fakeRunner().runner,
          node: "/bin/node",
          overlays: join(root, "o")
        }
      )
      const gateway = {
        name: "codevisor",
        url: "http://127.0.0.1:9/mcp?gateway=g",
        bearerToken: "t"
      }
      const account = { ...managed, env: { [AGY_GEMINI_DIR_ENV]: join(root, "gemini") } }
      await run(antigravity.createSession(definition, "/repo", recorder().emit, account, gateway))
      expect(agy.processes[0]!.request.env).toMatchObject({
        CODEVISOR_MCP_GATEWAY_URL: gateway.url,
        CODEVISOR_MCP_GATEWAY_TOKEN: "t"
      })
      expect(
        JSON.parse(await readFile(join(root, "gemini", "config", "mcp_config.json"), "utf8"))
      ).toMatchObject({ mcpServers: { codevisor: { command: "/bin/node" } } })
      await run(
        antigravity.loadSession(definition, "c-1", "/repo", recorder().emit, undefined, gateway)
      )
      expect(agy.processes[1]!.request.args).toEqual(
        expect.arrayContaining([
          expect.stringMatching(new RegExp(`^--gemini_dir=${join(root, "o")}/`))
        ])
      )
    } finally {
      await rm(root, { recursive: true, force: true })
    }
  })

  it("lists models once an hour, and checks the version once", async () => {
    let now = 0
    const { commands, provider: antigravity } = provider({ now: () => now })
    await run(antigravity.createSession(definition, "/repo", recorder().emit))
    await run(antigravity.createSession(definition, "/repo", recorder().emit))
    now = 60 * 60_000
    await run(antigravity.createSession(definition, "/repo", recorder().emit))
    expect(commands.calls.map((call) => call.args.join(" "))).toEqual([
      "--version",
      "models",
      "models"
    ])
  })

  it("refuses an agy too old for headless chats, and checks again after an update", async () => {
    const { commands, provider: antigravity } = provider({
      answers: { "--version": { stdout: "1.2.12\n" } }
    })
    await expect(
      run(antigravity.createSession(definition, "/repo", recorder().emit))
    ).rejects.toThrow(
      "Antigravity CLI (1.2.12) is too old for Codevisor. Update it to 1.3.0 or newer."
    )
    await expect(
      run(antigravity.createSession(definition, "/repo", recorder().emit))
    ).rejects.toThrow("too old")
    expect(commands.calls.filter((call) => call.args[0] === "--version")).toHaveLength(2)
    const minimum = provider({ answers: { "--version": { stdout: "1.3\n" } } })
    await run(minimum.provider.createSession(definition, "/repo", recorder().emit))
    const blank = provider({ answers: { "--version": { stdout: "" } } })
    await expect(
      run(blank.provider.createSession(definition, "/repo", recorder().emit))
    ).rejects.toThrow("(unknown)")
  })

  it("needs a sign-in to start when agy won't list models signed out", async () => {
    const { provider: antigravity } = provider({
      answers: { models: { code: 1, stderr: "Error: Please sign in to view available models." } }
    })
    await expect(
      run(antigravity.createSession(definition, "/repo", recorder().emit))
    ).rejects.toThrow(SIGN_IN_DETAIL)
  })

  it("starts on agy's default model when the catalog won't list", async () => {
    const { agy, provider: antigravity } = provider({
      answers: { models: { code: 1, stderr: "Error: backend unavailable" } }
    })
    await run(antigravity.createSession(definition, "/repo", recorder().emit))
    expect(agy.processes[0]!.request.args).not.toContain("--model")
    const crashed = provider({ answers: { models: new Error("spawn EACCES") } })
    const created = await run(crashed.provider.createSession(definition, "/repo", recorder().emit))
    expect(created.metadata.configOptions).toEqual([])
  })

  it("keeps a catalog it listed before when a refresh fails", async () => {
    let now = 0
    let listing = true
    const runner = vi.fn(async (request: { args: ReadonlyArray<string> }) => {
      if (request.args[0] === "--version") return { code: 0, stdout: "1.3.4", stderr: "" }
      if (listing) return { code: 0, stdout: "gpt-oss-120b  GPT-OSS 120B", stderr: "" }
      return { code: 1, stdout: "", stderr: "Error: backend unavailable" }
    })
    const { provider: antigravity } = provider({ now: () => now, runner })
    await run(antigravity.createSession(definition, "/repo", recorder().emit))
    listing = false
    now = 2 * 60 * 60_000
    const created = await run(antigravity.createSession(definition, "/repo", recorder().emit))
    expect(created.metadata.configOptions[0]!.currentValue).toBe("gpt-oss-120b")
  })

  it("resumes a conversation and drives the chat through its handle", async () => {
    const { agy, provider: antigravity } = provider({
      opens: (process) => process.init("c-old")
    })
    const loaded = await run(antigravity.loadSession(definition, "c-old", "/repo", recorder().emit))
    expect(loaded.sessionId).toBe("c-old")
    const first = agy.processes[0]!
    expect(first.request.args.slice(-2)).toEqual(["--conversation", "c-old"])
    const prompt = run(loaded.handle.prompt("hi"))
    await first.sends()
    await expect(run(loaded.handle.cancel)).resolves.toEqual({ runtimeState: "reusable" })
    first.result({ status: "INTERRUPTED" })
    await expect(prompt).resolves.toEqual({ stopReason: "cancelled" })
    await expect(run(loaded.handle.setConfigOption("thought_level", "high"))).resolves.toHaveLength(
      2
    )
    await expect(run(loaded.handle.setMode("plan"))).rejects.toThrow(
      "Antigravity has no mode named plan"
    )
    await run(loaded.handle.close)
    expect(first.closed).toBe(true)
  })

  it("lists conversations from the user's or the account's own index", async () => {
    const read = vi.fn(async (_path: string) => [
      { conversation_id: "c-1", workspace_uris: "file:///repo", last_modified_time: 1 }
    ])
    const { provider: antigravity } = provider({ readSummaries: read })
    await expect(antigravity.listAgentSessions!(definition)).resolves.toEqual([
      { sessionId: "c-1", cwd: "/repo", updatedAt: "1970-01-01T00:00:01.000Z" }
    ])
    await antigravity.listAgentSessions!(definition, managed)
    expect(read.mock.calls).toEqual([
      ["/home/me/.gemini/antigravity-cli/conversation_summaries.db"],
      ["/p/gemini/antigravity-cli/conversation_summaries.db"]
    ])
    const homeless = makeAntigravityProvider({ ...environment, env: {} }, { readSummaries: read })
    await homeless.listAgentSessions!(definition)
    expect(read.mock.calls[2]![0]).toBe(
      `${process.cwd()}/.gemini/antigravity-cli/conversation_summaries.db`
    )
  })

  it("probes the sign-in by listing models, keeping the catalog for chats", async () => {
    const { commands, provider: antigravity } = provider()
    await expect(run(antigravity.probeAuth!(definition, managed))).resolves.toMatchObject({
      state: "authenticated"
    })
    await run(antigravity.createSession(definition, "/repo", recorder().emit, managed))
    expect(commands.calls.filter((call) => call.args.includes("models"))).toHaveLength(1)

    const empty = provider({ answers: { models: { stdout: "" } } })
    await run(empty.provider.probeAuth!(definition))
    await run(empty.provider.createSession(definition, "/repo", recorder().emit))
    expect(empty.commands.calls.filter((call) => call.args.includes("models"))).toHaveLength(2)

    const signedOut = provider({
      answers: { models: { code: 1, stderr: "Error: Please sign in to view available models." } }
    })
    await expect(run(signedOut.provider.probeAuth!(definition))).resolves.toMatchObject({
      state: "unauthenticated"
    })
    const broken = provider({
      answers: { models: new Error("Antigravity didn't respond in time.") }
    })
    await expect(run(broken.provider.probeAuth!(definition))).resolves.toEqual({
      state: "error",
      methods: [],
      canLogout: false,
      detail: "Antigravity didn't respond in time."
    })
    const blank = provider({ answers: { models: new Error("") } })
    await expect(run(blank.provider.probeAuth!(definition))).resolves.toMatchObject({
      detail: "Couldn't check Antigravity's sign-in."
    })
  })
})
