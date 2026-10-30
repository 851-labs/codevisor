import { chmodSync, mkdtempSync, rmSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"

import { makeOpenCode2Logins, type OpenCodeServer } from "@codevisor/adapter-opencode"
import { makeDatabase, type CodevisorDatabaseService } from "@codevisor/db"
import { Effect } from "effect"
import { afterEach, describe, expect, it, vi } from "vitest"

import { makeHarnessAuthManager } from "./harness-auth.js"
import { fakeAgentRuntime, fakeTerminalManager } from "./harness-lifecycle-test-support.js"
import type {
  ClaudeAgentIntegration,
  SharedProviderIntegration
} from "./shared-provider-integration.js"

const run = <A, E>(effect: Effect.Effect<A, E>): Promise<A> => Effect.runPromise(effect)
const directories: string[] = []
const databases: CodevisorDatabaseService[] = []

afterEach(async () => {
  await Promise.all(databases.splice(0).map((database) => run(database.close)))
  for (const directory of directories.splice(0)) rmSync(directory, { force: true, recursive: true })
})

const scriptedServer = (answer: (path: string) => unknown) => {
  const calls: string[] = []
  let markStopped!: () => void
  const stopped = new Promise<void>((resolve) => {
    markStopped = resolve
  })
  const server: OpenCodeServer = {
    url: "http://oc",
    request: async (path: string) => {
      calls.push(path)
      return answer(path)
    },
    subscribe: vi.fn(),
    stop: vi.fn(async () => markStopped())
  }
  return { server, calls, stopped }
}

const claudeAgentLogin = {
  id: "claude-login",
  type: "oauth" as const,
  label: "Claude account in Codevisor",
  prompts: []
}

const setup = async (
  overrides: {
    readonly removed?: boolean
    readonly saved?: Record<string, unknown>
    readonly claudeAgent?: ClaudeAgentIntegration
  } = {}
) => {
  const directory = mkdtempSync(join(tmpdir(), "codevisor-opencode2-auth-"))
  directories.push(directory)
  const binary = join(directory, "opencode")
  writeFileSync(binary, "#!/bin/sh\nexit 0\n")
  chmodSync(binary, 0o700)
  const db = await run(
    makeDatabase({ filename: join(directory, "codevisor.sqlite"), serverId: "test" })
  )
  databases.push(db)
  await run(
    db.saveHarnessAccount({
      id: "opencode-default",
      harnessId: "opencode",
      profileKind: "default",
      label: "Default",
      authState: "authenticated",
      canLogin: true,
      canLogout: false
    })
  )
  const control = scriptedServer((path) => (path === "/api/integration" ? { data: [] } : undefined))
  const accounts = {
    providers: vi.fn(async () => [
      { id: "openai", name: "OpenAI", methods: [] },
      { id: "anthropic", name: "Anthropic", methods: [] },
      { id: "claude-agent", name: "Claude Agent", methods: [claudeAgentLogin] }
    ]),
    hold: vi.fn(async () => ({ server: control.server, release: vi.fn() })),
    removeIntegration: vi.fn(async () => undefined)
  }
  const shared = {
    configured: vi.fn(async () => ["openai"]),
    disabled: vi.fn(async () => []),
    capture: vi.fn(async () => true),
    remove: vi.fn(async () => overrides.removed ?? false),
    context: vi.fn<SharedProviderIntegration["context"]>(async () => {
      throw new Error("context is not stubbed")
    }),
    ...(overrides.claudeAgent === undefined ? {} : { claudeAgent: overrides.claudeAgent })
  } satisfies SharedProviderIntegration
  const isolated = scriptedServer((path) => {
    if (path.endsWith("/connect/oauth"))
      return {
        data: {
          attemptID: "con_1",
          url: "https://auth.test",
          instructions: "Enter code",
          mode: "auto"
        }
      }
    if (path.endsWith("/con_1")) return { data: { status: "complete" } }
    return {
      data: [
        overrides.saved ?? {
          integrationID: "openai",
          active: true,
          value: { type: "oauth", refresh: "r", access: "a", expires: 9 }
        }
      ]
    }
  })
  const start = vi.fn(async (_options: { readonly env: NodeJS.ProcessEnv }) => isolated.server)
  const manager = makeHarnessAuthManager({
    agents: fakeAgentRuntime(),
    dataDir: directory,
    db,
    terminal: fakeTerminalManager(),
    resolveEnv: () => Promise.resolve({ HOME: directory, PATH: directory }),
    openCode: {
      majorVersion: async () => 2,
      accounts,
      start,
      logins: makeOpenCode2Logins({ wait: async () => undefined })
    },
    sharedProviders: () => shared
  })
  return { manager, accounts, shared, control, isolated, start, binary }
}

describe("OpenCode 2 accounts", () => {
  it("lists a profile's providers from OpenCode 2's own catalog, keeping shared sign-ins", async () => {
    const { manager, accounts, binary } = await setup()
    expect(await manager.openCodeProviders!("opencode-default")).toEqual([
      { id: "openai", name: "OpenAI", methods: [], credentialType: "oauth" },
      { id: "anthropic", name: "Anthropic", methods: [] },
      { id: "claude-agent", name: "Claude Agent", methods: [] }
    ])
    expect(accounts.providers).toHaveBeenCalledWith(expect.objectContaining({ command: binary }))
  })

  it("signs a shareable provider in on a throwaway server and keeps the sign-in in Codevisor's vault", async () => {
    const { manager, shared, isolated, start } = await setup()
    const flow = await manager.beginOpenCodeLogin!(
      "opencode-default",
      "openai",
      "chatgpt-headless",
      undefined,
      undefined,
      true
    )
    expect(flow).toMatchObject({
      state: "running",
      authorization: { url: "https://auth.test", method: "auto" }
    })
    const env = start.mock.calls[0]![0].env
    expect(env.XDG_DATA_HOME).toMatch(/harness-logins\/opencode\/[\w-]+\/data$/)
    expect(env.OPENCODE_CONFIG_CONTENT).toBe("{}")
    await isolated.stopped
    expect(manager.openCodeLoginFlow!(flow.id).state).toBe("complete")
    expect(shared.capture).toHaveBeenCalledWith(
      "opencode",
      "opencode-default",
      "openai",
      { type: "oauth", refresh: "r", access: "a", expires: 9 },
      true
    )
  })

  it("refuses to share an OpenCode Console sign-in that names another server", async () => {
    const { manager, shared, isolated } = await setup({
      saved: {
        integrationID: "opencode",
        active: true,
        value: {
          type: "oauth",
          refresh: "r",
          access: "a",
          expires: 9,
          metadata: { server: "https://attacker.example", accountID: "usr_1" }
        }
      }
    })
    const flow = await manager.beginOpenCodeLogin!(
      "opencode-default",
      "opencode",
      "device",
      undefined,
      undefined,
      true
    )
    await isolated.stopped
    expect(manager.openCodeLoginFlow!(flow.id)).toMatchObject({
      state: "error",
      error:
        "OpenCode Console sign-ins must come from https://opencode.ai/console. Codevisor won't share one from https://attacker.example."
    })
    expect(shared.capture).not.toHaveBeenCalled()
  })

  it("saves a key in the profile itself, replacing a shared sign-in for that provider", async () => {
    const { manager, shared, control, start } = await setup()
    const flow = await manager.beginOpenCodeLogin!(
      "opencode-default",
      "openai",
      "key",
      undefined,
      "sk-test"
    )
    expect(flow.state).toBe("complete")
    expect(control.calls).toEqual(["/api/integration", "/api/integration/openai/connect/key"])
    expect(start).not.toHaveBeenCalled()
    expect(shared.remove).toHaveBeenCalledWith("opencode", "opencode-default", "openai", false)
  })

  it("signs a profile out of a provider it signed in to itself", async () => {
    const own = await setup()
    await own.manager.logoutOpenCodeProvider!("opencode-default", "anthropic")
    expect(own.accounts.removeIntegration).toHaveBeenCalledWith(
      expect.objectContaining({ command: own.binary }),
      "anthropic"
    )
    const sharedSignIn = await setup({ removed: true })
    await sharedSignIn.manager.logoutOpenCodeProvider!("opencode-default", "openai")
    expect(sharedSignIn.accounts.removeIntegration).not.toHaveBeenCalled()
  })

  it("hands Claude Agent's sign-in to Codevisor's Claude accounts", async () => {
    const waiting = {
      id: "claude-flow",
      accountId: "opencode-default",
      providerId: "claude-agent",
      state: "waiting" as const
    }
    const claudeAgent = {
      provider: vi.fn(async (_profile: string, listed) => ({ ...listed, accountLabel: "alice" })),
      begin: vi.fn(async () => waiting),
      flow: vi.fn((flowId: string) => (flowId === waiting.id ? waiting : undefined)),
      answer: vi.fn(async () => ({ ...waiting, state: "complete" as const })),
      cancel: vi.fn(async () => undefined)
    } satisfies ClaudeAgentIntegration
    const { manager, start } = await setup({ claudeAgent })

    expect((await manager.openCodeProviders!("opencode-default", true))[2]).toEqual({
      id: "claude-agent",
      name: "Claude Agent",
      methods: [claudeAgentLogin],
      accountLabel: "alice"
    })
    expect(claudeAgent.provider).toHaveBeenCalledWith(
      "opencode-default",
      expect.objectContaining({ id: "claude-agent" }),
      true
    )
    const inputs = { account: "new" }
    expect(
      await manager.beginOpenCodeLogin!("opencode-default", "claude-agent", "claude-login", inputs)
    ).toBe(waiting)
    expect(claudeAgent.begin).toHaveBeenCalledWith("opencode-default", inputs)
    expect(manager.openCodeLoginFlow!(waiting.id)).toBe(waiting)
    expect(await manager.answerOpenCodeLogin!(waiting.id, "code")).toMatchObject({
      state: "complete"
    })
    manager.cancelOpenCodeLogin!(waiting.id)
    expect(claudeAgent.cancel).toHaveBeenCalledWith(waiting.id)
    expect(start).not.toHaveBeenCalled()
  })
})
