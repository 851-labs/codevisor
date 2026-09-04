import { harnessCatalog, type AgentRuntimeService } from "@codevisor/agent-runtime"
import type { Harness } from "@codevisor/api"
import { makeDatabase, type CodevisorDatabaseService } from "@codevisor/db"
import type { TerminalManagerService } from "@codevisor/terminal"
import { Effect } from "effect"
import { chmodSync, mkdtempSync, rmSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { afterEach, describe, expect, it, vi } from "vitest"
import { makeHarnessAuthManager } from "./harness-auth.js"

const run = <A, E>(effect: Effect.Effect<A, E>): Promise<A> => Effect.runPromise(effect)

const directories: string[] = []
const databases: CodevisorDatabaseService[] = []

afterEach(async () => {
  vi.useRealTimers()
  await Promise.all(databases.splice(0).map((database) => run(database.close)))
  for (const directory of directories.splice(0)) {
    rmSync(directory, { force: true, recursive: true })
  }
})

describe("Pi harness authentication", () => {
  it("routes Pi setup to the native provider manager instead of ACP or a terminal", async () => {
    const directory = mkdtempSync(join(tmpdir(), "codevisor-pi-auth-"))
    directories.push(directory)

    const db = await run(
      makeDatabase({ filename: join(directory, "codevisor.sqlite"), serverId: "test" })
    )
    databases.push(db)
    const account = await run(
      db.saveHarnessAccount({
        id: "pi-account",
        harnessId: "pi",
        profileKind: "default",
        label: "Pi configuration",
        authState: "unauthenticated",
        canLogin: true,
        canLogout: false
      })
    )

    const authenticateHarness = vi.fn(() => Effect.void)
    const agents = {
      authenticateHarness,
      probeHarnessAuth: vi.fn(() =>
        Effect.succeed({
          state: "unauthenticated" as const,
          methods: [
            {
              id: "pi_terminal_login",
              name: "Launch pi in the terminal",
              description: "Configure Pi providers"
            }
          ],
          canLogout: false
        })
      )
    } as unknown as AgentRuntimeService
    const terminal = {} as TerminalManagerService
    const manager = makeHarnessAuthManager({
      agents,
      dataDir: directory,
      db,
      terminal,
      resolveEnv: () => Promise.resolve({ HOME: directory })
    })
    const definition = harnessCatalog.find((candidate) => candidate.id === "pi")!
    const harness: Harness = {
      id: definition.id,
      name: definition.name,
      symbolName: definition.symbolName,
      source: "registry",
      launchKind: "npx",
      enabled: true,
      readiness: { state: "ready", path: "/usr/local/bin/pi" }
    }

    const [decorated] = await manager.decorateHarnesses([harness], true)
    expect(decorated?.enabled).toBe(false)
    expect(decorated?.auth?.loginMethods).toEqual([])
    await expect(manager.beginLogin(account.id)).rejects.toThrow(
      "Choose and authenticate a Pi provider in Codevisor settings"
    )
    expect(authenticateHarness).not.toHaveBeenCalled()
  })
})

describe("activate-time account rebinding", () => {
  it("rebinds sessions pinned to dead accounts and frees them for removal", async () => {
    const directory = mkdtempSync(join(tmpdir(), "codevisor-auth-activate-"))
    directories.push(directory)
    const db = await run(
      makeDatabase({ filename: join(directory, "codevisor.sqlite"), serverId: "test" })
    )
    databases.push(db)
    const project = await run(
      db.createProject({ name: "Sweep", folderPath: join(directory, "project") })
    )
    const saveAccount = (id: string, authState: "expired" | "unauthenticated" | "authenticated") =>
      run(
        db.saveHarnessAccount({
          id,
          harnessId: "gemini",
          profileKind: "managed",
          profileKey: id,
          label: id,
          authState,
          canLogin: true,
          canLogout: true
        })
      )
    const dead = await saveAccount("gemini-dead", "expired")
    const fresh = await saveAccount("gemini-fresh", "unauthenticated")
    const healthy = await saveAccount("gemini-healthy", "authenticated")
    const pinnedToDead = await run(
      db.createSession({ projectId: project.id, harnessId: "gemini", harnessAccountId: dead.id })
    )
    const pinnedToHealthy = await run(
      db.createSession({
        projectId: project.id,
        harnessId: "gemini",
        harnessAccountId: healthy.id
      })
    )

    const agents = {
      probeHarnessAuth: vi.fn(() =>
        Effect.succeed({ state: "authenticated" as const, methods: [], canLogout: true })
      )
    } as unknown as AgentRuntimeService
    const manager = makeHarnessAuthManager({
      agents,
      dataDir: directory,
      db,
      terminal: {} as TerminalManagerService,
      resolveEnv: () => Promise.resolve({ HOME: directory })
    })
    await manager.activateAccount("gemini", fresh.id)

    // Sessions pinned to an unusable account follow the activated one; a
    // session using a working account keeps its pin.
    expect((await run(db.getSessionSummary(pinnedToDead.id))).harnessAccountId).toBe(fresh.id)
    expect((await run(db.getSessionSummary(pinnedToHealthy.id))).harnessAccountId).toBe(healthy.id)
    // With no session referencing it anymore, the dead account can finally be
    // removed (removal refuses while sessions reference an account).
    await manager.removeAccount(dead.id)
    expect(await run(db.getHarnessAccount(dead.id))).toBeUndefined()
  })
})

describe("harness authentication refresh", () => {
  it("refreshes every account when one harness probe fails", async () => {
    const directory = mkdtempSync(join(tmpdir(), "codevisor-auth-refresh-"))
    directories.push(directory)

    const db = await run(
      makeDatabase({ filename: join(directory, "codevisor.sqlite"), serverId: "test" })
    )
    databases.push(db)
    await Promise.all([
      run(
        db.saveHarnessAccount({
          id: "pi-account",
          harnessId: "pi",
          profileKind: "default",
          label: "Pi configuration",
          authState: "checking",
          canLogin: true,
          canLogout: false
        })
      ),
      run(
        db.saveHarnessAccount({
          id: "gemini-account",
          harnessId: "gemini",
          profileKind: "default",
          label: "Existing Gemini CLI account",
          authState: "checking",
          canLogin: true,
          canLogout: false
        })
      )
    ])

    const probeHarnessAuth = vi.fn((harnessId: string) =>
      harnessId === "gemini"
        ? Effect.fail(new Error("ACP connection closed"))
        : Effect.succeed({
            state: "notRequired" as const,
            methods: [],
            canLogout: false
          })
    )
    const manager = makeHarnessAuthManager({
      agents: { probeHarnessAuth } as unknown as AgentRuntimeService,
      dataDir: directory,
      db,
      terminal: {} as TerminalManagerService,
      resolveEnv: () => Promise.resolve({ HOME: directory })
    })

    await expect(manager.refresh()).resolves.toBeUndefined()

    expect(probeHarnessAuth).toHaveBeenCalledWith("pi", expect.any(Object))
    expect(probeHarnessAuth).toHaveBeenCalledWith("gemini", expect.any(Object))
    await expect(run(db.getHarnessAccount("pi-account"))).resolves.toMatchObject({
      authState: "notRequired"
    })
    await expect(run(db.getHarnessAccount("gemini-account"))).resolves.toMatchObject({
      authState: "error",
      canLogout: false
    })
  })

  it("persists and emits one error when concurrent refreshes share a failed probe", async () => {
    const directory = mkdtempSync(join(tmpdir(), "codevisor-auth-single-flight-"))
    directories.push(directory)

    const db = await run(
      makeDatabase({ filename: join(directory, "codevisor.sqlite"), serverId: "test" })
    )
    databases.push(db)
    await run(
      db.saveHarnessAccount({
        id: "opencode-account",
        harnessId: "opencode",
        profileKind: "default",
        label: "Existing OpenCode profile",
        authState: "checking",
        canLogin: true,
        canLogout: false
      })
    )

    let releaseProbe: () => void = () => undefined
    const probeGate = new Promise<void>((resolve) => {
      releaseProbe = resolve
    })
    const probeHarnessAuth = vi.fn(() =>
      Effect.promise(async () => {
        await probeGate
        throw new Error("ACP initialize timed out after 10000ms")
      })
    )
    const manager = makeHarnessAuthManager({
      agents: { probeHarnessAuth } as unknown as AgentRuntimeService,
      dataDir: directory,
      db,
      terminal: {} as TerminalManagerService,
      resolveEnv: () => Promise.resolve({ HOME: directory })
    })
    const events: string[] = []
    manager.subscribe((event) => events.push(event.kind))
    const listAccounts = vi.spyOn(db, "listHarnessAccounts")

    const waiterCount = 64
    const refreshes = Array.from({ length: waiterCount }, () => manager.refresh("opencode"))
    await vi.waitFor(() =>
      expect(listAccounts.mock.calls.length).toBeGreaterThanOrEqual(waiterCount)
    )
    await vi.waitFor(() => expect(probeHarnessAuth).toHaveBeenCalledTimes(1))
    releaseProbe()
    await Promise.all(refreshes)

    expect(probeHarnessAuth).toHaveBeenCalledTimes(1)
    expect(events.filter((kind) => kind === "harness.account.updated")).toHaveLength(1)
    expect(events.filter((kind) => kind === "harness.auth.updated")).toHaveLength(1)
    await expect(run(db.getHarnessAccount("opencode-account"))).resolves.toMatchObject({
      authState: "error",
      detail: "ACP initialize timed out after 10000ms"
    })
  })
})

describe("OpenCode profile authentication", () => {
  it("creates managed profiles with isolated XDG directories", async () => {
    const directory = mkdtempSync(join(tmpdir(), "codevisor-opencode-profile-"))
    directories.push(directory)
    const db = await run(
      makeDatabase({ filename: join(directory, "codevisor.sqlite"), serverId: "test" })
    )
    databases.push(db)
    const probeHarnessAuth = vi.fn(() =>
      Effect.succeed({
        state: "authenticated" as const,
        methods: [],
        canLogout: false
      })
    )
    const manager = makeHarnessAuthManager({
      agents: { probeHarnessAuth } as unknown as AgentRuntimeService,
      dataDir: directory,
      db,
      terminal: {} as TerminalManagerService,
      resolveEnv: () =>
        Promise.resolve({ HOME: directory, OPENCODE_AUTH_CONTENT: '{"openai":{"type":"api"}}' })
    })

    const account = await manager.createAccount("opencode", "Work")
    const context = await manager.accountContext(account.id)
    const profile = join(directory, "harness-profiles", "opencode", account.id)
    expect(context).toMatchObject({
      id: account.id,
      profileKind: "managed",
      profilePath: profile,
      env: {
        XDG_DATA_HOME: join(profile, "data"),
        XDG_CONFIG_HOME: join(profile, "config"),
        XDG_STATE_HOME: join(profile, "state"),
        XDG_CACHE_HOME: join(profile, "cache")
      }
    })
    expect(probeHarnessAuth).toHaveBeenCalledWith(
      "opencode",
      expect.objectContaining({ id: account.id, profilePath: profile })
    )
  })
})

describe("Claude authentication probing", () => {
  const setup = async (
    execute: NonNullable<Parameters<typeof makeHarnessAuthManager>[0]["execFile"]>
  ) => {
    const directory = mkdtempSync(join(tmpdir(), "codevisor-claude-auth-"))
    directories.push(directory)
    const binary = join(directory, "claude")
    writeFileSync(binary, "#!/bin/sh\nexit 0\n")
    chmodSync(binary, 0o700)
    const db = await run(
      makeDatabase({ filename: join(directory, "codevisor.sqlite"), serverId: "test" })
    )
    databases.push(db)
    const account = await run(
      db.saveHarnessAccount({
        id: "claude-account",
        harnessId: "claude-code",
        profileKind: "default",
        label: "Existing Claude Code account",
        authState: "checking",
        canLogin: true,
        canLogout: false
      })
    )
    const manager = makeHarnessAuthManager({
      agents: {} as AgentRuntimeService,
      dataDir: directory,
      db,
      terminal: {} as TerminalManagerService,
      execFile: execute,
      resolveEnv: () => Promise.resolve({ HOME: directory, PATH: directory })
    })
    return { account, directory, manager }
  }

  it("runs status from the account's durable home instead of the daemon cwd", async () => {
    const execute = vi.fn(async () => ({
      stdout: JSON.stringify({
        loggedIn: true,
        authMethod: "claude.ai",
        email: "person@example.com"
      }),
      stderr: ""
    }))
    const { account, directory, manager } = await setup(execute)

    await expect(manager.probeAccount(account.id, true)).resolves.toMatchObject({
      authState: "authenticated",
      canLogout: true
    })
    expect(execute).toHaveBeenCalledWith(
      join(directory, "claude"),
      ["auth", "status", "--json"],
      expect.objectContaining({ cwd: directory })
    )
  })

  it("reports an execution failure as an error instead of signed out", async () => {
    const execute = vi.fn(async () => {
      throw Object.assign(new Error("spawn failed"), {
        code: 1,
        stdout: "",
        stderr: "ENOENT: current working directory no longer exists"
      })
    })
    const { account, manager } = await setup(execute)

    await expect(manager.probeAccount(account.id, true)).resolves.toMatchObject({
      authState: "error",
      canLogout: false,
      detail: "Unable to check Claude sign-in (Claude exited with status 1)"
    })
  })

  it("still recognizes Claude's explicit signed-out response", async () => {
    const execute = vi.fn(async () => {
      throw Object.assign(new Error("signed out"), {
        code: 1,
        stdout: `{
  "loggedIn": false,
  "authMethod": "none",
  "apiProvider": "firstParty"
}`,
        stderr: ""
      })
    })
    const { account, manager } = await setup(execute)

    await expect(manager.probeAccount(account.id, true)).resolves.toMatchObject({
      authState: "unauthenticated",
      canLogout: false
    })
  })
})

describe("Claude wrapped OAuth login", () => {
  it("begins a pasteCode flow, completes on the pasted code, and cancels cleanly", async () => {
    const directory = mkdtempSync(join(tmpdir(), "codevisor-claude-auth-"))
    directories.push(directory)
    const db = await run(
      makeDatabase({ filename: join(directory, "codevisor.sqlite"), serverId: "test" })
    )
    databases.push(db)
    const account = await run(
      db.saveHarnessAccount({
        id: "claude-account",
        harnessId: "claude-code",
        profileKind: "default",
        label: "Personal",
        authState: "unauthenticated",
        canLogin: true,
        canLogout: false
      })
    )
    // The post-answer probe runs the real CLI shape: a fake binary that
    // reports a signed-in account.
    const binary = join(directory, "claude")
    writeFileSync(
      binary,
      '#!/bin/sh\necho \'{"loggedIn": true, "authMethod": "claude.ai", "email": "u@example.com"}\'\n'
    )
    chmodSync(binary, 0o700)

    const calls: Array<Array<string>> = []
    const claudeAuth = () => ({
      start: async () => {
        calls.push(["start"])
        return { url: "https://claude.com/cai/oauth/authorize?state=abc" }
      },
      submit: async (pasted: string) => {
        calls.push(["submit", pasted])
      },
      close: () => {
        calls.push(["close"])
      }
    })
    const manager = makeHarnessAuthManager({
      agents: {} as AgentRuntimeService,
      claudeAuth,
      dataDir: directory,
      db,
      terminal: {} as TerminalManagerService,
      resolveEnv: () =>
        Promise.resolve({ HOME: directory, PATH: `${directory}:${process.env.PATH}` })
    })

    const flow = await manager.beginLogin(account.id)
    expect(flow).toMatchObject({
      accountId: account.id,
      kind: "pasteCode",
      url: "https://claude.com/cai/oauth/authorize?state=abc"
    })

    const done = await manager.answerLogin(flow.id, "the-code#the-state")
    expect(done.kind).toBe("complete")
    expect(calls).toContainEqual(["submit", "the-code#the-state"])
    expect(calls).toContainEqual(["close"])
    const probed = await manager.probeAccount(account.id)
    expect(probed.authState).toBe("authenticated")

    // A fresh flow cancels by closing its client; answering it afterwards
    // reports expiry instead of a dangling exchange.
    const second = await manager.beginLogin(account.id)
    await manager.cancelLogin(second.id)
    await expect(manager.answerLogin(second.id, "x#y")).rejects.toThrow("expired")
  })
})
