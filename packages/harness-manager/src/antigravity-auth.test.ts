import { mkdtemp, rm, stat } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"

import type { AgyRunner, AgyTerminal, AgyTerminalSpawner } from "@codevisor/adapter-antigravity"
import type { HarnessAccount } from "@codevisor/api"
import type { HarnessAccountRecord } from "@codevisor/db"
import { Effect } from "effect"
import { describe, expect, it, vi } from "vitest"

import { makeAntigravityAuth } from "./antigravity-auth.js"
import type { HarnessAuthCore } from "./harness-auth-core.js"

const URL_ = "https://accounts.google.com/o/oauth2/auth?client_id=1"

const account = (fields: Partial<HarnessAccountRecord> = {}) =>
  ({
    id: "acct-1",
    harnessId: "antigravity",
    profileKind: "managed",
    ...fields
  }) as HarnessAccountRecord

const terminals = (agy: { signedIn: boolean; refuses: boolean; quits: boolean }) => {
  const opened: Array<{ written: Array<string>; killed: boolean }> = []
  const spawn: AgyTerminalSpawner = async () => {
    const state = { written: [] as Array<string>, killed: false }
    opened.push(state)
    let draw: ((data: string) => void) | undefined
    const terminal: AgyTerminal = {
      write: (data) => {
        state.written.push(data)
        if (data.startsWith("\x1b") || !data.endsWith("\r") || data.length === 1) return
        if (agy.refuses) draw?.("Error: invalid_grant\r\n")
        else agy.signedIn = true
      },
      onData: (handler) => {
        draw = handler
        if (!agy.quits) queueMicrotask(() => draw?.(`\x1b]8;;${URL_}\x07link\x1b]8;;\x07`))
      },
      onExit: (handler) => {
        if (agy.quits) queueMicrotask(() => handler(1))
      },
      kill: () => {
        state.killed = true
      }
    }
    return terminal
  }
  return { spawn, opened }
}

const setup = (
  options: {
    signedInBefore?: boolean
    logout?: { code: number; stderr?: string }
    signedIn?: boolean
    accounts?: ReadonlyArray<HarnessAccountRecord>
    profiles?: string
    sync?: boolean
    refuses?: boolean
    quits?: boolean
  } = {}
) => {
  const saved: Array<HarnessAccountRecord> = []
  const events: Array<{ kind: string; payload: unknown }> = []
  const setActive = vi.fn(() => Effect.void)
  const sync = {
    captureLogin: vi.fn(async () => undefined),
    loginFailed: vi.fn(async () => undefined)
  }
  const core = {
    accountCommand: async () => ({
      cwd: "/profile",
      env: { HOME: "/home/me", CODEVISOR_AGY_GEMINI_DIR: "/profile/gemini" }
    }),
    executable: async () => "/bin/agy",
    emit: (event: { kind: string; payload: unknown }) => void events.push(event),
    profilePath: (record: HarnessAccountRecord) => join(options.profiles ?? "/profiles", record.id),
    publicAccount: (record: HarnessAccountRecord) => ({ id: record.id }),
    config: {
      ...(options.sync === true ? { sharedAccounts: () => sync } : {}),
      db: {
        setActiveHarnessAccount: setActive,
        listHarnessAccounts: () => Effect.succeed(options.accounts ?? []),
        saveHarnessAccount: (record: HarnessAccountRecord) => {
          saved.push(record)
          return Effect.succeed(record)
        }
      }
    }
  } as unknown as HarnessAuthCore
  const agy = {
    signedIn: options.signedInBefore ?? false,
    refuses: options.refuses ?? false,
    quits: options.quits ?? false
  }
  const calls: Array<ReadonlyArray<string>> = []
  const runner: AgyRunner = async (request) => {
    calls.push(request.args)
    if (request.args.includes("/logout"))
      return { stdout: "", stderr: "", ...options.logout, code: options.logout?.code ?? 0 }
    return { code: agy.signedIn ? 0 : 1, stdout: "", stderr: "" }
  }
  const probe = vi.fn(
    async () =>
      ({
        authState: options.signedIn === false ? "unauthenticated" : "authenticated"
      }) as HarnessAccount
  )
  const tty = terminals(agy)
  const auth = makeAntigravityAuth(core, probe, tty.spawn, runner, async () => undefined)
  return { auth, events, setActive, calls, probe, tty, saved, sync }
}

describe("Antigravity sign-in", () => {
  it("shows agy's Google link as a paste-code step for a managed account", async () => {
    const { auth, events } = setup()
    const flow = await auth.begin(account())
    expect(flow).toEqual({ id: flow.id, accountId: "acct-1", kind: "pasteCode", url: URL_ })
    expect(events).toEqual([
      { kind: "harness.authFlow.updated", subjectId: "antigravity", payload: flow }
    ])
    expect(auth.owns(flow.id)).toBe(true)
  })

  it("signs in an account of its own rather than the user's Keychain one", async () => {
    const managed = account()
    expect(await setup().auth.managedAccount(managed)).toBe(managed)
    const idle = account({ id: "acct-idle", authState: "unauthenticated" })
    const reused = setup({
      accounts: [
        account({ id: "default", profileKind: "default" }),
        account({ id: "acct-ok", authState: "authenticated" }),
        idle
      ]
    })
    expect(await reused.auth.managedAccount(account({ profileKind: "default" }))).toBe(idle)
    expect(reused.saved).toEqual([])

    const profiles = await mkdtemp(join(tmpdir(), "agy-auth-"))
    try {
      const fresh = setup({ profiles })
      const created = await fresh.auth.managedAccount(account({ profileKind: "default" }))
      expect(created).toMatchObject({
        harnessId: "antigravity",
        profileKind: "managed",
        profileKey: created.id,
        authState: "unauthenticated",
        canLogin: true
      })
      expect((await stat(join(profiles, created.id))).mode & 0o777).toBe(0o700)
      expect(fresh.events).toEqual([
        { kind: "harness.account.updated", subjectId: "antigravity", payload: { id: created.id } }
      ])
    } finally {
      await rm(profiles, { recursive: true, force: true })
    }
  })

  it("replaces an account's earlier sign-in attempt", async () => {
    const { auth, tty } = setup()
    const first = await auth.begin(account())
    await auth.begin(account())
    expect(tty.opened[0]!.killed).toBe(true)
    expect(auth.owns(first.id)).toBe(false)
    const other = await auth.begin(account({ id: "acct-2" }))
    await auth.begin(account())
    expect(auth.owns(other.id)).toBe(true)
  })

  it("finishes with the pasted code and makes the account active", async () => {
    const { auth, calls, events, probe, setActive, tty } = setup()
    const flow = await auth.begin(account())
    await expect(auth.answer(flow.id, "4/0Abc")).resolves.toEqual({
      id: flow.id,
      accountId: "acct-1",
      kind: "complete"
    })
    expect(tty.opened[0]!.written.at(-1)).toBe("4/0Abc\r")
    expect(calls).toEqual([
      ["--gemini_dir=/profile/gemini", "models"],
      ["--gemini_dir=/profile/gemini", "models"]
    ])
    expect(probe).toHaveBeenCalledWith("acct-1", true)
    expect(setActive).toHaveBeenCalledWith("antigravity", "acct-1")
    expect(events.at(-1)).toMatchObject({ payload: { kind: "complete" } })
    expect(auth.owns(flow.id)).toBe(false)
    await expect(auth.answer(flow.id, "again")).rejects.toThrow("expired")
  })

  it("finishes at once for an account that's already signed in", async () => {
    const { auth, events, setActive, tty } = setup({ signedInBefore: true })
    const flow = await auth.begin(account())
    expect(flow).toEqual({ id: flow.id, accountId: "acct-1", kind: "complete" })
    expect(tty.opened).toEqual([])
    expect(setActive).toHaveBeenCalledWith("antigravity", "acct-1")
    expect(events).toEqual([
      { kind: "harness.authFlow.updated", subjectId: "antigravity", payload: flow }
    ])
  })

  it("hands a finished sign-in to account sync, which shares it", async () => {
    const { auth, probe, setActive, sync } = setup({ sync: true })
    const flow = await auth.begin(account())
    await auth.answer(flow.id, "4/0Abc")
    expect(sync.captureLogin).toHaveBeenCalledWith("acct-1")
    expect(probe).not.toHaveBeenCalled()
    expect(setActive).not.toHaveBeenCalled()
  })

  it("tells account sync when a sign-in doesn't land", async () => {
    const refused = setup({ sync: true, refuses: true })
    const flow = await refused.auth.begin(account())
    await expect(refused.auth.answer(flow.id, "bad")).rejects.toThrow("invalid_grant")
    expect(refused.sync.loginFailed).toHaveBeenCalledWith("acct-1")
    expect(refused.sync.captureLogin).not.toHaveBeenCalled()

    const cancelled = setup({ sync: true })
    await cancelled.auth.cancel((await cancelled.auth.begin(account())).id)
    expect(cancelled.sync.loginFailed).toHaveBeenCalledWith("acct-1")

    const quit = setup({ sync: true, quits: true })
    await expect(quit.auth.begin(account())).rejects.toThrow(
      "closed before it showed a sign-in link"
    )
    expect(quit.sync.loginFailed).toHaveBeenCalledWith("acct-1")

    await expect(setup({ quits: true }).auth.begin(account())).rejects.toThrow("closed before")
  })

  it("doesn't make an account active that still isn't signed in", async () => {
    const { auth, setActive } = setup({ signedIn: false })
    const flow = await auth.begin(account())
    await auth.answer(flow.id, "code")
    expect(setActive).not.toHaveBeenCalled()
  })

  it("cancels an attempt by closing agy", async () => {
    const { auth, tty } = setup()
    const flow = await auth.begin(account())
    await auth.cancel(flow.id)
    await auth.cancel("unknown")
    expect(tty.opened[0]!.killed).toBe(true)
    expect(auth.owns(flow.id)).toBe(false)
  })

  it("signs out through agy's own /logout", async () => {
    const ok = setup()
    await ok.auth.logout(account())
    expect(ok.calls).toEqual([["--gemini_dir=/profile/gemini", "--print", "/logout"]])
    await expect(
      setup({ logout: { code: 1, stderr: "Error: not signed in\n" } }).auth.logout(account())
    ).rejects.toThrow("Error: not signed in")
    await expect(setup({ logout: { code: 1 } }).auth.logout(account())).rejects.toThrow(
      "Antigravity couldn't sign out."
    )
  })
})
