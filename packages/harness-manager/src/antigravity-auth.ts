import { randomUUID } from "node:crypto"
import { chmod, mkdir } from "node:fs/promises"
import { setTimeout as sleep } from "node:timers/promises"

import {
  agyAccountLaunch,
  runAgy,
  spawnAgyTerminal,
  startAgyLogin,
  type AgyLogin,
  type AgyRunner,
  type AgyTerminalSpawner
} from "@codevisor/adapter-antigravity"
import type { HarnessAccount, HarnessAuthFlow } from "@codevisor/api"
import type { HarnessAccountRecord } from "@codevisor/db"

import { ANTIGRAVITY_HARNESS_ID } from "./antigravity-profile.js"
import type { HarnessAuthCore } from "./harness-auth-core.js"
import { run } from "./harness-auth-support.js"

export { ANTIGRAVITY_HARNESS_ID }

/// Antigravity's Google sign-in, hosted by Codevisor: agy's own TUI runs in
/// a hidden terminal on the account's data root, Codevisor shows its OAuth
/// link, and the code Google's callback page shows comes back through the
/// paste-code step. Works from a remote Codevisor server too.
export const makeAntigravityAuth = (
  core: HarnessAuthCore,
  probeAccount: (accountId: string, force: boolean) => Promise<HarnessAccount>,
  spawn: AgyTerminalSpawner = spawnAgyTerminal,
  runner: AgyRunner = runAgy,
  wait: (ms: number) => Promise<unknown> = sleep
) => {
  const logins = new Map<string, { accountId: string; login: AgyLogin }>()

  const agy = async (account: HarnessAccountRecord, args: ReadonlyArray<string>) => {
    const execution = await core.accountCommand(account)
    const launch = agyAccountLaunch(execution.env)
    return runner({
      command: await core.executable(ANTIGRAVITY_HARNESS_ID),
      args: [...launch.args, ...args],
      cwd: execution.cwd,
      env: launch.env,
      timeoutMs: 30_000
    })
  }

  /// The account a sign-in lands in. The user's own agy keeps its sign-in in
  /// the Keychain, which only agy's own terminal login writes; signing in
  /// from Codevisor makes (or reuses a signed-out) managed account instead.
  const managedAccount = async (account: HarnessAccountRecord): Promise<HarnessAccountRecord> => {
    if (account.profileKind === "managed") return account
    const accounts = await run(core.config.db.listHarnessAccounts(ANTIGRAVITY_HARNESS_ID))
    const idle = accounts.find(
      (entry) => entry.profileKind === "managed" && entry.authState !== "authenticated"
    )
    if (idle !== undefined) return idle
    const id = randomUUID()
    const created = await run(
      core.config.db.saveHarnessAccount({
        id,
        harnessId: ANTIGRAVITY_HARNESS_ID,
        profileKind: "managed",
        profileKey: id,
        label: `Account ${id.slice(0, 6)}`,
        authState: "unauthenticated",
        canLogin: true,
        canLogout: false
      })
    )
    const path = core.profilePath(created)!
    await mkdir(path, { recursive: true, mode: 0o700 })
    await chmod(path, 0o700)
    core.emit({
      kind: "harness.account.updated",
      subjectId: ANTIGRAVITY_HARNESS_ID,
      payload: core.publicAccount(created)
    })
    return created
  }

  /// Marks a sign-in done. With account sync on, the sign-in landed in a
  /// fresh managed profile: sync seals its token file into the shared vault
  /// and every machine gets it. Otherwise the account's state is re-read and,
  /// signed in, it becomes the one chats use.
  const finish = async (accountId: string, flowId: string): Promise<HarnessAuthFlow> => {
    const shared = core.config.sharedAccounts?.()
    if (shared) await shared.captureLogin(accountId)
    else {
      const result = await probeAccount(accountId, true)
      if (result.authState === "authenticated")
        await run(core.config.db.setActiveHarnessAccount(ANTIGRAVITY_HARNESS_ID, accountId))
    }
    const done: HarnessAuthFlow = { id: flowId, accountId, kind: "complete" }
    core.emit({
      kind: "harness.authFlow.updated",
      subjectId: ANTIGRAVITY_HARNESS_ID,
      payload: done
    })
    return done
  }

  /// Tells account sync, when it's on, that this sign-in didn't land.
  const loginFailed = async (accountId: string): Promise<void> => {
    await core.config.sharedAccounts?.()?.loginFailed(accountId)
  }

  const begin = async (account: HarnessAccountRecord): Promise<HarnessAuthFlow> => {
    for (const [flowId, entry] of logins)
      if (entry.accountId === account.id) {
        entry.login.cancel()
        logins.delete(flowId)
      }
    // Signed in already, agy skips its login screen: there's no link to show.
    if ((await agy(account, ["models"])).code === 0) return finish(account.id, randomUUID())
    let login: AgyLogin
    try {
      const execution = await core.accountCommand(account)
      login = await startAgyLogin({
        spawn,
        command: await core.executable(ANTIGRAVITY_HARNESS_ID),
        cwd: execution.cwd,
        env: execution.env,
        signedIn: async () => (await agy(account, ["models"])).code === 0,
        wait
      })
    } catch (cause) {
      await loginFailed(account.id)
      throw cause
    }
    const id = randomUUID()
    logins.set(id, { accountId: account.id, login })
    const flow: HarnessAuthFlow = { id, accountId: account.id, kind: "pasteCode", url: login.url }
    core.emit({
      kind: "harness.authFlow.updated",
      subjectId: ANTIGRAVITY_HARNESS_ID,
      payload: flow
    })
    return flow
  }

  const owns = (flowId: string): boolean => logins.has(flowId)

  const answer = async (flowId: string, code: string): Promise<HarnessAuthFlow> => {
    const entry = logins.get(flowId)
    if (entry === undefined) throw new Error("This sign-in attempt has expired — start again")
    // The terminal closes either way: a rejected code needs a new link.
    logins.delete(flowId)
    try {
      await entry.login.submit(code)
      return await finish(entry.accountId, flowId)
    } catch (cause) {
      await loginFailed(entry.accountId)
      throw cause
    }
  }

  const cancel = async (flowId: string): Promise<void> => {
    const entry = logins.get(flowId)
    if (entry === undefined) return
    entry.login.cancel()
    logins.delete(flowId)
    await loginFailed(entry.accountId)
  }

  /// agy answers its own slash commands in print mode.
  const logout = async (account: HarnessAccountRecord): Promise<void> => {
    const result = await agy(account, ["--print", "/logout"])
    if (result.code !== 0) throw new Error(result.stderr.trim() || "Antigravity couldn't sign out.")
  }

  return { managedAccount, begin, owns, answer, cancel, logout }
}

export type AntigravityAuth = ReturnType<typeof makeAntigravityAuth>
