import { randomUUID } from "node:crypto"

import type { HarnessAccount, HarnessAuthFlow } from "@codevisor/api"
import type { HarnessAccountRecord } from "@codevisor/db"

import { loginGrok, GROK_CLIENT_ID, GROK_ISSUER } from "./grok-device-auth.js"
import type { HarnessAuthCore } from "./harness-auth-core.js"

interface Login {
  accountId: string
  shared: boolean
  abort: AbortController
  done: Promise<void>
}

// Use the same device-code handoff as Codex, with Grok's own OAuth
// contract. Never launch a browser on the machine running the harness.
export const makeGrokAuth = (core: HarnessAuthCore) => {
  const logins = new Map<string, Login>()
  const failures = new Map<string, string>()
  const scope = (accountId: string, shared: boolean) => JSON.stringify([accountId, shared])
  const integration = () => {
    const shared = core.config.sharedProviders?.()
    if (!shared?.account) throw new Error("Account sync is unavailable. Try again when connected.")
    return shared
  }
  const cancel = async (id: string) => {
    const login = logins.get(id)
    if (!login) return
    login.abort.abort()
    await login.done
    failures.delete(scope(login.accountId, login.shared))
  }
  const account = async (row: HarnessAccountRecord, shared = false): Promise<HarnessAccount> => {
    const value = await integration().account!(core.publicAccount(row), shared)
    const pending = [...logins.values()].some(
      (login) => login.accountId === row.id && login.shared === shared
    )
    const error = failures.get(scope(row.id, shared))
    const result =
      pending || error
        ? {
            ...value,
            authState: pending ? ("checking" as const) : ("error" as const),
            ...(error ? { detail: error } : {})
          }
        : value
    if (!shared) {
      await core.persistProbe(row, {
        authState: result.authState,
        authMethod: result.authMethod ?? null,
        label: result.label,
        email: result.email ?? null,
        canLogin: result.canLogin,
        canLogout: result.canLogout,
        detail: result.detail ?? null
      })
    }
    return result
  }
  const begin = async (
    row: HarnessAccountRecord,
    method = "grok.com",
    apiKey?: string,
    shared = false
  ): Promise<HarnessAuthFlow> => {
    const providers = integration()
    for (const [id, login] of logins) {
      if (login.accountId === row.id && login.shared === shared) await cancel(id)
    }
    failures.delete(scope(row.id, shared))
    const id = randomUUID()
    if (method === "apiKey") {
      if (!apiKey?.trim()) throw new Error("Enter an API key")
      const saved = await providers.capture(
        "grok-build",
        "default",
        "xai",
        { auth_mode: "api_key", key: apiKey.trim() },
        shared
      )
      if (!saved) throw new Error("API key could not be saved. Try again.")
      await account(row, shared)
      return { id, accountId: row.id, kind: "complete" }
    }
    if (method !== "grok.com") throw new Error("Choose a Grok sign-in method")
    const loginOAuth = core.config.grokOAuth?.login ?? loginGrok
    const abort = new AbortController()
    const login: Login = { accountId: row.id, shared, abort, done: Promise.resolve() }
    logins.set(id, login)
    const ready = Promise.withResolvers<HarnessAuthFlow>()
    login.done = (async () => {
      try {
        const credential = await loginOAuth({
          signal: AbortSignal.any([abort.signal, AbortSignal.timeout(10 * 60_000)]),
          notify: (event) => {
            if (event.type !== "device_code" || abort.signal.aborted) return
            const flow: HarnessAuthFlow = {
              id,
              accountId: row.id,
              kind: "deviceCode",
              verificationUrl: event.verificationUri,
              userCode: event.userCode
            }
            ready.resolve(flow)
            core.emit({ kind: "harness.authFlow.updated", subjectId: "grok-build", payload: flow })
          },
          prompt: async () => {
            throw new Error("Grok requires device-code sign-in")
          }
        })
        if (abort.signal.aborted) throw new Error("Sign-in canceled")
        if (
          !(await providers.capture(
            "grok-build",
            "default",
            "xai",
            {
              auth_mode: "oidc",
              key: credential.access,
              refresh_token: credential.refresh,
              expires_at: new Date(credential.expires).toISOString(),
              id_token: credential.idToken,
              oidc_issuer: GROK_ISSUER,
              oidc_client_id: GROK_CLIENT_ID
            },
            shared
          ))
        )
          throw new Error("Sign-in could not be saved")
        const flow: HarnessAuthFlow = { id, accountId: row.id, kind: "complete" }
        ready.resolve(flow)
        core.emit({ kind: "harness.authFlow.updated", subjectId: "grok-build", payload: flow })
      } catch {
        const message = abort.signal.aborted
          ? "Sign-in canceled"
          : "Couldn't sign in to Grok. Try again."
        if (!abort.signal.aborted) failures.set(scope(row.id, shared), message)
        ready.reject(new Error(message))
      } finally {
        logins.delete(id)
        core.emit({
          kind: "harness.account.updated",
          subjectId: "grok-build",
          payload: { id: row.id }
        })
      }
    })()
    return ready.promise
  }
  return {
    account,
    begin,
    cancel,
    logout: async (row: HarnessAccountRecord, shared = false) => {
      for (const [id, login] of logins) {
        if (login.accountId === row.id && login.shared === shared) await cancel(id)
      }
      failures.delete(scope(row.id, shared))
      await integration().remove("grok-build", "default", "xai", shared)
      return account(row, shared)
    }
  }
}
export type GrokAuth = ReturnType<typeof makeGrokAuth>
