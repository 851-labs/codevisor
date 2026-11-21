import { mkdtempSync, rmSync } from "node:fs"
import { join } from "node:path"

import type { Harness } from "@codevisor/api"
import { FIRST_RUN_PROJECTS_PENDING, FIRST_RUN_PROJECTS_SETTING } from "@codevisor/db"
import type { SharedTokenBundle } from "@codevisor/harness-manager"
import { Effect } from "effect"
import { describe, expect, it, onTestFinished, vi } from "vitest"

import { importFirstRunProjects } from "./first-run-project-import.js"
import { readFirstRunStatus } from "./first-run-status.js"
import { fleet, native } from "./infra/shared-accounts-test-support.js"
import { defaultServerConfig } from "./server-config.js"
import { makeEventFanout } from "./server-context.js"
import { jsonRequest, run, startWithApp } from "./test-support.js"

describe("asking about Claude Code's sign-in on first run", () => {
  it("asks once Claude Code is installed and signed in, and still asks after a restart", async () => {
    const mac = await makeMac()
    mac.claude.signIn(claudeCodeLogin)

    await mac.importProjects()
    await mac.shared.reconcile()

    expect((await mac.status()).claudeCodeLogin).toEqual({ email: "alice@example.test" })
    expect((await readFirstRunStatus({ ...mac.services })).claudeCodeLogin).toEqual({
      email: "alice@example.test"
    })
    expect(mac.claude.login()).toEqual(claudeCodeLogin)
  })

  it.each([
    ["Claude Code isn't installed", [codex], claudeCodeLogin],
    ["Claude Code isn't signed in", [claude], undefined]
  ])("doesn't ask when %s", async (_case, harnesses, login) => {
    const mac = await makeMac(harnesses)
    mac.claude.signIn(login)

    await mac.importProjects()

    expect((await mac.status()).claudeCodeLogin).toBeUndefined()
  })

  it.each([
    ["signIn", claudeCodeLogin, 0],
    ["notNow", claudeCodeLogin, 0],
    ["transfer", undefined, 1]
  ] as const)(
    "answers %s over HTTP, then stops asking",
    async (choice, leftInClaudeCode, codevisorLogins) => {
      const mac = await makeMac()
      mac.claude.signIn(claudeCodeLogin)
      await mac.importProjects()
      const server = await mac.start()

      expect((await server.answer({ choice: "maybe" })).status).toBe(400)
      expect((await server.answer({ choice })).status).toBe(200)

      expect(mac.claude.login()).toEqual(leftInClaudeCode)
      expect(await mac.shared.accounts("claude-code", true)).toHaveLength(codevisorLogins)
      expect((await mac.status()).claudeCodeLogin).toBeUndefined()
      expect((await server.answer({ choice })).status).toBe(404)
    }
  )

  it("doesn't ask again when first run starts over after an answer", async () => {
    const mac = await makeMac()
    mac.claude.signIn(claudeCodeLogin)
    await mac.importProjects()
    const server = await mac.start()
    await server.answer({ choice: "notNow" })
    await run(
      mac.services.db.setMachineSetting(FIRST_RUN_PROJECTS_SETTING, FIRST_RUN_PROJECTS_PENDING)
    )

    await mac.importProjects()

    expect((await mac.status()).claudeCodeLogin).toBeUndefined()
  })

  it("keeps asking when Claude Code's sign-in can no longer be moved", async () => {
    const mac = await makeMac()
    mac.claude.signIn(claudeCodeLogin)
    await mac.importProjects()
    const server = await mac.start()
    mac.claude.signIn(undefined)

    expect((await server.answer({ choice: "transfer" })).status).toBe(409)
    expect((await mac.status()).claudeCodeLogin).toEqual({ email: "alice@example.test" })
  })
})

const claudeCodeLogin: SharedTokenBundle = {
  ...native("alice"),
  harnessId: "claude-code",
  ownership: "managed",
  refreshToken: "machine-refresh"
}

const harness = (id: string, name: string): Harness => ({
  id,
  name,
  symbolName: "terminal",
  source: "registry",
  launchKind: "npx",
  enabled: true,
  readiness: { state: "ready" }
})

const claude = harness("claude-code", "Claude Code")

const codex = harness("codex", "Codex")

const makeMac = async (harnesses: ReadonlyArray<Harness> = [claude]) => {
  const home = mkdtempSync(join(process.cwd(), ".first-run-claude-login-"))
  vi.stubEnv("CODEVISOR_WORKTREES_ROOT", join(home, "managed"))
  vi.useFakeTimers({ toFake: ["Date"] })
  vi.setSystemTime(100_000)
  vi.spyOn(console, "error").mockImplementation(() => {})
  onTestFinished(() => {
    vi.unstubAllEnvs()
    vi.restoreAllMocks()
    vi.useRealTimers()
    rmSync(home, { force: true, recursive: true })
  })
  const m = await fleet().machine("test")
  const agents = {
    ...m.services.agents,
    discoverHarnesses: Effect.succeed(harnesses),
    listAgentSessions: () => Effect.succeed([])
  }
  const services = { ...m.services, agents }
  const fanout = await run(makeEventFanout)
  const config = defaultServerConfig({
    bootId: "boot",
    id: "test",
    firstRunProjects: {
      dataDirectory: home,
      homeDirectory: home,
      platform: "darwin",
      canReadFolder: () => Promise.resolve(true)
    }
  }).firstRunProjects!
  return {
    services,
    shared: m.shared,
    claude: m.claude,
    importProjects: () => importFirstRunProjects(services, fanout, "test", config),
    status: () => readFirstRunStatus(services),
    start: async () => {
      const server = await startWithApp(services, fanout, { id: "test", firstRunProjects: config })
      return {
        answer: (body: unknown) =>
          jsonRequest(server, "/v1/first-run/claude-code-login", {
            method: "POST",
            body: JSON.stringify(body)
          })
      }
    }
  }
}
