import { isoTimestamp, type HarnessAccount } from "@codevisor/api"
import type {
  CodevisorDatabaseService,
  HarnessAccountRecord,
  UpdateHarnessAccountAuthRequest
} from "@codevisor/db"
import { SharedCredentialError } from "@codevisor/harness-manager"
import type { SharedCredentialVault, SharedTokenBundle } from "@codevisor/harness-manager"
import { Effect } from "effect"

import { publicAccount } from "./shared-account-local-rows.js"
import type { SharedAccountLocalState } from "./shared-account-local-state.js"
import {
  sharedHarness,
  type SharedAccountStore,
  type SharedHarnessAccount
} from "./shared-account-store.js"

export interface SharedAccountCredentialsDeps {
  readonly db: CodevisorDatabaseService
  readonly store: SharedAccountStore
  readonly vault: SharedCredentialVault
  readonly localState: SharedAccountLocalState
}

export const makeSharedAccountCredentials = ({
  db,
  store,
  vault,
  localState
}: SharedAccountCredentialsDeps) => {
  const resolve = async (id: string) => store.get(await localState.resolveAlias(id))

  const token = async (id: string, rejected?: string) => {
    const account = await resolve(id)
    if (!account?.credential) throw new SharedCredentialError("revoked")
    if (await localState.isDisabled(account.id)) throw new SharedCredentialError("revoked")

    return vault.token(account.credential, rejected)
  }

  const probe = async (id: string, shared = false): Promise<HarnessAccount | undefined> => {
    if (localState.isCapturingLogin(id)) return undefined
    if (await localState.isLoginPending(id))
      return publicAccount(await run(db.updateHarnessAccountAuth(id, pendingLoginAuth())))

    const account = await resolve(id)
    const native = await run(db.getHarnessAccount(id))
    if (!account && native && !sharedHarness(native.harnessId)) return undefined
    if (!account && !id.startsWith("shared-")) return undefined

    let status: ProbeStatus
    try {
      let bundle: SharedTokenBundle
      if (shared && account?.credential) bundle = await vault.token(account.credential)
      else bundle = await token(id)
      status = authenticated(bundle)
    } catch (cause) {
      status = probeFailure(account, cause)
    }

    const existing = await run(db.getHarnessAccount(id))
    if (!existing) return undefined
    if (shared) return sharedProbeResult(existing, status)

    return publicAccount(await run(db.updateHarnessAccountAuth(id, probedAuth(status))))
  }

  return { resolve, token, probe }
}

export type SharedAccountCredentials = ReturnType<typeof makeSharedAccountCredentials>

interface ProbeStatus {
  readonly authState: "authenticated" | "expired" | "unauthenticated"
  readonly authMethod: "oauth" | "apiKey"
  readonly detail: string | null
}

const run = Effect.runPromise

const pendingLoginAuth = (): UpdateHarnessAccountAuthRequest => ({
  authState: "checking",
  canLogin: true,
  canLogout: false,
  detail: null
})

const authenticated = (bundle: SharedTokenBundle): ProbeStatus => ({
  authState: "authenticated",
  authMethod: bundle.authMethod ?? "oauth",
  detail: null
})

const probeFailure = (account: SharedHarnessAccount | undefined, cause: unknown): ProbeStatus => {
  const authState = account?.credential ? "expired" : "unauthenticated"
  return { authState, authMethod: "oauth", detail: failureDetail(cause) }
}

const failureDetail = (cause: unknown): string => {
  if (cause instanceof SharedCredentialError) return cause.message
  return "Account sync is unavailable. Try again."
}

const sharedProbeResult = (existing: HarnessAccountRecord, status: ProbeStatus): HarnessAccount => {
  const { detail: _detail, ...value } = publicAccount(existing)
  return {
    ...value,
    authState: status.authState,
    authMethod: status.authMethod,
    canLogin: true,
    canLogout: status.authState === "authenticated",
    ...(status.detail ? { detail: status.detail } : {})
  }
}

const probedAuth = (status: ProbeStatus): UpdateHarnessAccountAuthRequest => ({
  authState: status.authState,
  authMethod: status.authMethod,
  detail: status.detail,
  canLogin: true,
  canLogout: status.authState === "authenticated",
  lastCheckedAt: isoTimestamp()
})
