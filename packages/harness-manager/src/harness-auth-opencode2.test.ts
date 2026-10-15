import { chmodSync, mkdtempSync, rmSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"

import { makeOpenCode2Logins, type OpenCodeServer } from "@codevisor/adapter-opencode"
import { makeDatabase, type CodevisorDatabaseService } from "@codevisor/db"
import { Effect } from "effect"
import { afterEach, describe, expect, it, vi } from "vitest"

import { makeHarnessAuthManager } from "./harness-auth.js"
import { fakeAgentRuntime, fakeTerminalManager } from "./harness-lifecycle-test-support.js"
import type { SharedProviderIntegration } from "./shared-provider-integration.js"

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
    request: async <A>(path: string): Promise<A> => {
      calls.push(path)
      // oxlint-disable-next-line typescript/no-unsafe-type-assertion
      return answer(path) as A
    },
    stop: vi.fn(async () => markStopped())
  }
  return { server, calls, stopped }
}

const setup = async (overrides: { readonly removed?: boolean } = {}) => {
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
  const control = scriptedServer(() => undefined)
  const accounts = {
    providers: vi.fn(async () => [
      { id: "openai", name: "OpenAI", methods: [] },
      { id: "anthropic", name: "Anthropic", methods: [] }
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
    })
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
        {
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
      { id: "anthropic", name: "Anthropic", methods: [] }
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
})
