import { randomUUID } from "node:crypto"
import { join } from "node:path"

import type { HarnessAccountContext } from "@codevisor/agent-runtime"
import type { HarnessAccount } from "@codevisor/api"
import type { CodevisorDatabaseService, HarnessAccountRecord } from "@codevisor/db"
import {
  removeAntigravityAuth,
  removeMuseAuth,
  SharedCredentialError
} from "@codevisor/harness-manager"
import type {
  HarnessAuthManager,
  SharedCredentialVault,
  SharedOAuthHarness
} from "@codevisor/harness-manager"
import { Effect } from "effect"

import { sharedAccountContext } from "./shared-account-context.js"
import type { SharedAccountCredentials } from "./shared-account-credentials.js"
import { publicAccount, type LocalAccountRows } from "./shared-account-local-rows.js"
import type { SharedAccountLocalState } from "./shared-account-local-state.js"
import type { ClaudeProfileLogins } from "./shared-account-profile-logins.js"
import {
  sharedHarness,
  type SharedAccountStore,
  type SharedHarnessAccount
} from "./shared-account-store.js"
import type { makeSharedClaudeGateway } from "./shared-claude-gateway.js"

export interface SharedAccountLifecycleDeps {
  readonly db: CodevisorDatabaseService
  readonly auth: HarnessAuthManager
  readonly store: SharedAccountStore
  readonly vault: SharedCredentialVault
  readonly localState: SharedAccountLocalState
  readonly localRows: LocalAccountRows
  readonly credentials: SharedAccountCredentials
  readonly profileLogins: ClaudeProfileLogins
  readonly gateway: ReturnType<typeof makeSharedClaudeGateway>
  readonly dataDir: string
  readonly environment: () => Promise<NodeJS.ProcessEnv>
  readonly options: { readonly baseUrl: string }
}

export const makeSharedAccountLifecycle = (deps: SharedAccountLifecycleDeps) => {
  const { db, store, localState, localRows, credentials, gateway, dataDir } = deps

  const create = async (harnessId: SharedOAuthHarness, label?: string) => {
    const account: SharedHarnessAccount = {
      id: `shared-${randomUUID()}`,
      harnessId,
      label: label?.trim() || "New Account",
      createdAt: Date.now()
    }
    await store.save(account)
    return publicAccount(await localRows.save(account))
  }

  const prepareLogin = async (id: string, method?: string): Promise<string> => {
    const row = await run(db.getHarnessAccount(id))
    if (!row || !sharedHarness(row.harnessId) || method === "apiKey") return id

    const fresh = await deps.auth.createAccount(row.harnessId, row.label)
    await localState.prepareLogin(fresh.id, id)
    return fresh.id
  }

  const context = async (id: string): Promise<HarnessAccountContext | undefined> => {
    const account = await credentials.resolve(id)
    if (!account) {
      const native = await run(db.getHarnessAccount(id))
      if (revokedSharedAccount(id, native)) throw new SharedCredentialError("revoked")
      return undefined
    }

    const bundle = await credentials.token(id)
    if (account.harnessId === "claude-code") await deps.profileLogins.beforeSession(account.id)
    return sharedAccountContext(
      {
        dataDir,
        baseUrl: deps.options.baseUrl,
        environment: deps.environment,
        token: credentials.token,
        gateway,
        record: (recordId) => run(db.getHarnessAccount(recordId))
      },
      account,
      id,
      bundle
    )
  }

  const logout = async (id: string, shared = false): Promise<HarnessAccount | undefined> => {
    const account = await credentials.resolve(id)
    if (!account) return undefined

    if (shared) {
      if (account.credential) await deps.vault.revoke(account.credential)
      await store.remove(account.id)
    } else await localState.setDisabled(account.id, true)
    gateway.forget(account.id)

    const removeFileGrant = fileGrantRemovers.get(account.harnessId)
    if (removeFileGrant)
      await removeFileGrant(join(dataDir, "harness-profiles", account.harnessId, account.id))
    return credentials.probe(account.id)
  }

  const rename = async (id: string, label: string) => {
    const account = await credentials.resolve(id)
    if (!account) throw new Error("Account not found")

    await store.save(relabeled(account, label))
    await localRows.save(relabeled(account, label))
    return credentials.probe(account.id)
  }

  return {
    create,
    prepareLogin,
    loginFailed: (id: string) => localState.cancelLogin(id),
    context,
    logout,
    rename
  }
}

const run = Effect.runPromise

const fileGrantRemovers = new Map<string, (profile: string) => Promise<void>>([
  ["muse-code", removeMuseAuth],
  ["antigravity", removeAntigravityAuth]
])

const revokedSharedAccount = (id: string, native: HarnessAccountRecord | undefined): boolean =>
  id.startsWith("shared-") && (!native || sharedHarness(native.harnessId))

const relabeled = (account: SharedHarnessAccount, label: string): SharedHarnessAccount => ({
  ...account,
  label: label.trim() || account.label
})
