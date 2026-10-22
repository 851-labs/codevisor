import { join } from "node:path"

import type { CodevisorDatabaseService, HarnessAccountRecord } from "@codevisor/db"
import { sharedApiKey, sharedOAuthIdentity } from "@codevisor/harness-manager"
import type { SharedCredentialVault, SharedTokenBundle } from "@codevisor/harness-manager"
import { Effect } from "effect"

import { makeClaudeLoginTakeover, type MachineClaudeLogin } from "./claude-login-takeover.js"
import { machineLoginReplacesDeadGrant } from "./shared-account-dead-grants.js"
import type { LocalAccountRows } from "./shared-account-local-rows.js"
import type { SharedAccountLocalState } from "./shared-account-local-state.js"
import type { ClaudeProfileLogins } from "./shared-account-profile-logins.js"
import type { discoverNativeAccount } from "./shared-account-storage.js"
import {
  sharedAccountFor,
  sharedHarness,
  type SharedAccountStore,
  type SharedHarnessAccount
} from "./shared-account-store.js"

export interface SharedAccountImportsDeps {
  readonly db: CodevisorDatabaseService
  readonly store: SharedAccountStore
  readonly vault: SharedCredentialVault
  readonly localState: SharedAccountLocalState
  readonly localRows: LocalAccountRows
  readonly profileLogins: ClaudeProfileLogins
  readonly dataDir: string
  readonly serverId: string
  readonly environment: () => Promise<NodeJS.ProcessEnv>
  readonly discover: typeof discoverNativeAccount
  readonly claudeMachine: (env: NodeJS.ProcessEnv) => MachineClaudeLogin
  readonly probe: (id: string) => Promise<unknown>
}

export const makeSharedAccountImports = (deps: SharedAccountImportsDeps) => {
  const { db, store, vault, localState, localRows, profileLogins, serverId } = deps

  const importBundle = async (
    bundle: SharedTokenBundle,
    nativeId?: string,
    explicit = false,
    label?: string
  ) => {
    const id = sharedOAuthIdentity(bundle)
    const previous = await store.get(id)
    explicit ||= reclaimsManagedGrant(bundle, previous)
    const tombstone = (await store.entries()).some((entry) => entry.key === id && entry.deleted)
    if (tombstone && !explicit) return undefined

    if (!explicit && (await machineLoginReplacesDeadGrant(vault, bundle, previous))) {
      console.error(`Using this machine's ${bundle.harnessId} login: the synced sign-in expired`)
      explicit = true
    }

    const keptGrant = explicit ? undefined : previous?.credential
    if (keptGrant) {
      if (bundle.ownership === "external") await vault.publishExternal(keptGrant, bundle)
    } else {
      const credential = await vault.create(bundle)
      if (previous?.credential) await vault.revoke(previous.credential)
      await store.save(sharedAccountFor(bundle, credential, previous, serverId, label))
    }

    const saved = (await store.get(id))!
    await localRows.save(saved, keptGrant ? undefined : bundle)
    await linkNative(nativeId, saved)
    return saved
  }

  const linkNative = async (nativeId: string | undefined, account: SharedHarnessAccount) => {
    if (!nativeId || nativeId === account.id) return

    await localState.setAlias(nativeId, account.id)
    if (account.harnessId === "claude-code")
      await run(db.rebindHarnessAccountSessions(nativeId, account.id))
  }

  const takeover = makeClaudeLoginTakeover({
    vault,
    store,
    localState,
    record: async ({ login, credential, previous }, nativeId) => {
      await store.save(sharedAccountFor(login, credential, previous, serverId))
      const saved = (await store.get(sharedOAuthIdentity(login)))!
      await localRows.save(saved, login)
      await linkNative(nativeId, saved)
      await deps.probe(saved.id)
    },
    log: (line) => console.error(line),
    platform: process.platform
  })

  const nativeBundle = async (account: HarnessAccountRecord, managed: boolean) => {
    if (!sharedHarness(account.harnessId) || account.profileKind !== "managed") return undefined

    const path = managedProfilePath(deps.dataDir, account)
    return deps.discover(account.harnessId, path, false, managed, await deps.environment())
  }

  const captureLogin = async (id: string) => {
    const row = await run(db.getHarnessAccount(id))
    const target = await localState.loginTarget(id)
    if (!row || target === undefined) return

    const bundle = await nativeBundle(row, true)
    if (!bundle || lacksStorableGrant(bundle))
      throw new Error("Sign-in could not be saved. Try signing in again.")

    const account = (await importBundle(bundle, id, true, row.label))!
    if (bundle.harnessId === "claude-code") await profileLogins.afterCapture(row)
    if (replacedPlaceholder(target, account) && !(await store.get(target))?.credential)
      await store.remove(target)

    await localState.setAlias(target, account.id)
    await localState.setDisabled(account.id, false)
    await localState.completeLogin(id, target)
    await localRows.applySelection(bundle.harnessId)
  }

  const adoptClaudeMachineLogin = async (env: NodeJS.ProcessEnv, nativeId: string | undefined) => {
    const machine = deps.claudeMachine(env)
    const login = await machine.read()
    if (login?.authMethod === "apiKey") await importBundle(login, nativeId)
    else await takeover.run(machine, login, nativeId)
  }

  const saveApiKey = async (id: string, key: string): Promise<void> => {
    const row = await run(db.getHarnessAccount(id))
    if (!row || !sharedHarness(row.harnessId) || !key.trim()) throw new Error("Enter an API key")

    const bundle = sharedApiKey(row.harnessId, key.trim())
    const account = (await importBundle(bundle, id, true, row.label))!
    if (replacedPlaceholder(id, account) && !(await store.get(id))?.credential)
      await store.remove(id)

    await localRows.applySelection(row.harnessId)
  }

  return { importBundle, nativeBundle, captureLogin, adoptClaudeMachineLogin, saveApiKey, takeover }
}

export type SharedAccountImports = ReturnType<typeof makeSharedAccountImports>

const run = Effect.runPromise

const fileGrantHarnesses = new Set(["muse-code", "antigravity"])

const reclaimsManagedGrant = (
  bundle: SharedTokenBundle,
  previous: SharedHarnessAccount | undefined
): boolean => !!(bundle.refreshToken && bundle.ownership === "managed" && previous?.sourceMachineId)

const lacksStorableGrant = (bundle: SharedTokenBundle): boolean =>
  !bundle.refreshToken && !fileGrantHarnesses.has(bundle.harnessId)

const replacedPlaceholder = (id: string, account: SharedHarnessAccount): boolean =>
  id.startsWith("shared-") && account.id !== id

const managedProfilePath = (dataDir: string, account: HarnessAccountRecord): string =>
  join(dataDir, "harness-profiles", account.harnessId, account.profileKey ?? account.id)
