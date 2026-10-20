import { createHash, randomBytes, randomUUID } from "node:crypto"

import type { HarnessNotice } from "@codevisor/api"
import {
  SharedCredentialError,
  fingerprint,
  sharedOAuthIdentity,
  type ClaudeRefreshLock,
  type SharedCredentialReference,
  type SharedCredentialVault,
  type SharedTokenBundle
} from "@codevisor/harness-manager"

import { failureMessage } from "../server-context.js"
import type { SharedAccountLocalState, TakeoverNotice } from "./shared-account-local-state.js"
import type { SharedAccountStore, SharedHarnessAccount } from "./shared-account-store.js"

export interface MachineClaudeLogin {
  readonly read: () => Promise<SharedTokenBundle | undefined>
  readonly whileLocked: <T>(body: (lock: ClaudeRefreshLock) => Promise<T>) => Promise<T>
  readonly signOut: () => Promise<void>
}

export interface ClaudeLoginTakeoverDeps {
  readonly vault: SharedCredentialVault
  readonly store: SharedAccountStore
  readonly localState: SharedAccountLocalState
  readonly record: (adoption: Adoption, nativeId: string | undefined) => Promise<void>
  readonly log: (line: string) => void
  readonly platform: string
}

export type NoticeListener = (harnessId: string, notice: HarnessNotice) => void

export interface Adoption {
  readonly login: SharedTokenBundle
  readonly credential: SharedCredentialReference
  readonly previous: SharedHarnessAccount | undefined
}

export const makeClaudeLoginTakeover = (deps: ClaudeLoginTakeoverDeps) => {
  const listeners = new Set<NoticeListener>()
  const noticeFor = (notice: TakeoverNotice): HarnessNotice => ({
    id: notice.id,
    message: takeoverMessage(deps.platform)
  })

  const report = (
    reference: SharedCredentialReference,
    login: SharedTokenBundle,
    outcome: string
  ) => deps.log(takeoverLine(reference, login, outcome))

  const adoptUnderLock = async (
    machine: MachineClaudeLogin,
    lock: ClaudeRefreshLock,
    nativeId: string | undefined
  ): Promise<Adoption | undefined> => {
    const login = await machine.read()
    if (!isTakeoverCandidate(login) || (await signedOutByUser(deps, login))) return undefined

    const adoption = await prepare(deps, login)
    if (!(await deps.vault.claim(adoption.credential, login))) {
      report(adoption.credential, login, "kept this machine's login: another machine adopted first")
      return undefined
    }

    await deps.record(adoption, nativeId)
    if (!(await deps.vault.confirm(adoption.credential, login)))
      throw new Error("the vault did not keep the adopted login")
    if (lock.isCompromised()) throw new Error("Claude Code's refresh lock was lost")

    await machine.signOut()
    return adoption
  }

  const finish = async (adoption: Adoption): Promise<void> => {
    report(adoption.credential, adoption.login, "adopted and signed Claude Code out")
    await deps.localState.forgetTakeoverKey(adoption.credential.id)
    await retire(deps, adoption)
    await announce()
  }

  const announce = async (): Promise<void> => {
    const notice = { id: randomUUID(), at: Date.now() }
    await deps.localState.setTakeoverNotice("claude-code", notice)
    for (const listener of listeners) listener("claude-code", noticeFor(notice))
  }

  const takeOver = async (machine: MachineClaudeLogin, nativeId: string | undefined) => {
    const adoption = await machine.whileLocked((lock) => adoptUnderLock(machine, lock, nativeId))
    if (adoption !== undefined) await finish(adoption)
  }

  const removeLeftoverCopy = async (
    machine: MachineClaudeLogin,
    login: TakeoverCandidate,
    holder: SharedCredentialReference
  ): Promise<void> => {
    const removed = await machine.whileLocked(async () => {
      if ((await machine.read())?.refreshToken !== login.refreshToken) return false

      await machine.signOut()
      return true
    })
    if (removed) report(holder, login, "removed a leftover copy from this machine")
  }

  const run = async (
    machine: MachineClaudeLogin,
    login: SharedTokenBundle | undefined,
    nativeId: string | undefined
  ): Promise<void> => {
    if (!isTakeoverCandidate(login)) return

    const codevisor = await codevisorLogins(deps)
    if (codevisor.unknown) return

    const holder = codevisor.holders.get(login.refreshToken)
    if (holder !== undefined) return removeLeftoverCopy(machine, login, holder)
    if (codevisor.live) return

    await takeOver(machine, nativeId)
  }

  return {
    notice: async (harnessId: string): Promise<HarnessNotice | undefined> => {
      const notice = await deps.localState.takeoverNotice(harnessId)
      if (notice === undefined || Date.now() - notice.at > noticeLifetimeMs) return undefined

      return noticeFor(notice)
    },
    subscribe: (listener: NoticeListener): (() => void) => {
      listeners.add(listener)
      return () => {
        listeners.delete(listener)
      }
    },
    run: async (
      machine: MachineClaudeLogin,
      login: SharedTokenBundle | undefined,
      nativeId: string | undefined
    ): Promise<void> => {
      try {
        await run(machine, login, nativeId)
      } catch (cause) {
        deps.log(takeoverSkippedLine("claude-code", failureMessage(cause)))
      }
    }
  }
}

export type ClaudeLoginTakeover = ReturnType<typeof makeClaudeLoginTakeover>

const takeoverLine = (
  reference: SharedCredentialReference,
  presented: SharedTokenBundle,
  outcome: string
): string =>
  `Machine login takeover ${presented.harnessId} login=${fingerprint(reference.id)} presented=${fingerprint(presented.refreshToken)}: ${outcome}`

const takeoverSkippedLine = (harnessId: string, reason: string): string =>
  `Machine login takeover ${harnessId}: kept this machine's login (${reason})`

const noticeLifetimeMs = 7 * 24 * 60 * 60_000

const takeoverMessage = (platform: string): string => {
  const machine = platform === "darwin" ? "this Mac" : "this machine"
  return `Claude is now signed in through Codevisor on all your machines. Claude Code on ${machine} was signed out.`
}

interface CodevisorLogins {
  readonly live: boolean
  readonly unknown: boolean
  readonly holders: ReadonlyMap<string, SharedCredentialReference>
}

type TakeoverCandidate = SharedTokenBundle & { readonly refreshToken: string }

const isTakeoverCandidate = (login: SharedTokenBundle | undefined): login is TakeoverCandidate =>
  login !== undefined && login.authMethod !== "apiKey" && login.refreshToken !== undefined

const signedOutByUser = async (
  deps: ClaudeLoginTakeoverDeps,
  login: SharedTokenBundle
): Promise<boolean> => {
  const id = sharedOAuthIdentity(login)
  const tombstone = (await deps.store.entries()).some((entry) => entry.key === id && entry.deleted)
  return tombstone || (await deps.localState.isDisabled(id))
}

const codevisorLogins = async (deps: ClaudeLoginTakeoverDeps): Promise<CodevisorLogins> => {
  let live = false
  let unknown = false
  const holders = new Map<string, SharedCredentialReference>()
  for (const account of await deps.store.accounts()) {
    if (!holdsClaudeCredential(account)) continue

    const state = await credentialState(deps.vault, account.credential)
    if (state === "unknown") unknown = true
    if (state === "dead" || state === "unknown") continue

    if (state.ownership === "managed") live = true
    if (state.refreshToken !== undefined) holders.set(state.refreshToken, account.credential)
  }
  return { live, unknown, holders }
}

const holdsClaudeCredential = (
  account: SharedHarnessAccount
): account is SharedHarnessAccount & { readonly credential: SharedCredentialReference } =>
  account.harnessId === "claude-code" && account.credential !== undefined

const credentialState = async (
  vault: SharedCredentialVault,
  credential: SharedCredentialReference
): Promise<SharedTokenBundle | "dead" | "unknown"> => {
  try {
    return await vault.token(credential)
  } catch (cause) {
    if (isDeadCredential(cause)) return "dead"
    return "unknown"
  }
}

const isDeadCredential = (cause: unknown): boolean =>
  cause instanceof SharedCredentialError &&
  (cause.reason === "reauthenticate" || cause.reason === "revoked")

const prepare = async (
  deps: ClaudeLoginTakeoverDeps,
  login: SharedTokenBundle
): Promise<Adoption> => {
  const accountId = sharedOAuthIdentity(login)
  const previous = await deps.store.get(accountId)
  const id = takeoverCredentialId(accountId, previous?.credential?.id)
  const key =
    (await deps.localState.takeoverKey(id)) ?? randomBytes(credentialKeyBytes).toString("base64url")
  await deps.localState.setTakeoverKey(id, key)
  return { login, credential: { id, key }, previous }
}

const credentialKeyBytes = 32
const takeoverIdLength = 32

const takeoverCredentialId = (accountId: string, replacing: string | undefined): string => {
  const digest = createHash("sha256").update(JSON.stringify([accountId, replacing ?? null]))
  return `takeover-${digest.digest("hex").slice(0, takeoverIdLength)}`
}

const retire = async (deps: ClaudeLoginTakeoverDeps, adoption: Adoption): Promise<void> => {
  const replaced = adoption.previous?.credential
  if (replaced === undefined || replaced.id === adoption.credential.id) return

  await deps.vault.revoke(replaced).catch((cause: unknown) => {
    deps.log(
      takeoverLine(
        replaced,
        adoption.login,
        `could not retire the replaced login (${failureMessage(cause)})`
      )
    )
  })
}
