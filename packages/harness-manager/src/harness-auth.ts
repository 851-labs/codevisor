import { randomUUID } from "node:crypto"
import { mkdir, readFile, rm } from "node:fs/promises"
import { join } from "node:path"

import { makeGrokAuth } from "./grok-auth.js"
import { makeHarnessAccountOperations } from "./harness-auth-accounts.js"
import { makeHarnessAuthCore } from "./harness-auth-core.js"
import { makeHarnessAuthDecoration } from "./harness-auth-decoration.js"
import { makeHarnessLoginOperations } from "./harness-auth-logins.js"
import { makeHarnessAuthProbes } from "./harness-auth-probes.js"
import { run } from "./harness-auth-support.js"
import type { HarnessAuthManager, HarnessAuthManagerConfig } from "./harness-auth-types.js"
import { makeOpenCodeAuthManager, openCodeAuthPath } from "./opencode-auth.js"
import type { OpenCodeProfile } from "./opencode-auth.js"
import { makePiAuthManager } from "./pi-auth.js"
import { reconcileSharedOpenCodeProfiles } from "./shared-opencode-profiles.js"
import { providerOAuthSupported } from "./shared-provider-oauth.js"

export type {
  HarnessAuthEvent,
  HarnessAuthManager,
  HarnessAuthManagerConfig
} from "./harness-auth-types.js"

export const makeHarnessAuthManager = (config: HarnessAuthManagerConfig): HarnessAuthManager => {
  const core = makeHarnessAuthCore(config)
  const { accountEnv, contextFor, environment, executable, listeners, persistProbe, profilePath } =
    core
  const piAuth = makePiAuthManager({
    resolveEnv: environment,
    saveCredential: async (providerId, credential, shared) => {
      if (credential.type === "oauth")
        return (
          (await config
            .sharedProviders?.()
            ?.capture("pi", "default", providerId, credential, shared)) ?? false
        )
      await config.sharedProviders?.()?.remove("pi", "default", providerId, shared)
      return false
    }
  })
  const openCodeProfile = async (accountId: string): Promise<OpenCodeProfile> => {
    const account = await run(config.db.getHarnessAccount(accountId))
    if (account === undefined) throw new Error(`Harness account not found: ${accountId}`)
    if (account.harnessId !== "opencode") throw new Error("Account is not an OpenCode profile")
    const env = await accountEnv(account)
    return {
      command: await executable("opencode"),
      cwd: profilePath(account) ?? env.HOME ?? process.cwd(),
      env,
      authPath: openCodeAuthPath(env)
    }
  }
  const openCodeAuth = makeOpenCodeAuthManager({
    profile: openCodeProfile,
    savedApiKey: async (accountId, providerId, shared) => {
      await config.sharedProviders?.()?.remove("opencode", accountId, providerId, shared)
    },
    loginProfile: async (accountId, providerId) => {
      if (!config.sharedProviders?.() || !providerOAuthSupported("opencode", providerId))
        return undefined
      const profile = await openCodeProfile(accountId)
      const data = join(config.dataDir, "harness-logins", "opencode", randomUUID())
      await mkdir(data, { recursive: true, mode: 0o700 })
      const env = { ...profile.env, XDG_DATA_HOME: data, OPENCODE_AUTH_CONTENT: "" }
      return { ...profile, env, authPath: openCodeAuthPath(env) }
    },
    captureOAuth: async (accountId, providerId, path, shared) => {
      const document = JSON.parse(await readFile(path, "utf8")) as Record<string, unknown>
      if (
        !(await config
          .sharedProviders?.()
          ?.capture("opencode", accountId, providerId, document[providerId], shared))
      )
        throw new Error("This provider cannot share its sign-in. Update Codevisor and try again.")
      await rm(path, { force: true })
    }
  })
  const grok = makeGrokAuth(core)
  const probes = makeHarnessAuthProbes(core, grok)
  const { probeAccount } = probes
  const decoration = makeHarnessAuthDecoration(core, probes)
  const accounts = makeHarnessAccountOperations(core, probes, decoration)
  const logins = makeHarnessLoginOperations(core, probes, grok)

  return {
    sharedOpenCodeProfiles: (content) =>
      reconcileSharedOpenCodeProfiles(
        { db: config.db, dataDir: config.dataDir, removeAccount: accounts.removeAccount },
        content
      ),
    decorateHarnesses: async (harnesses, force) => {
      await config.sharedAccounts?.()?.reconcile()
      return decoration.decorateHarnesses(harnesses, force)
    },
    decorateHarnessesFromStoredState: decoration.decorateHarnessesFromStoredState,
    refresh: decoration.refresh,
    ...accounts,
    ...logins,
    activateAccount: async (harnessId, accountId) => {
      if (await config.sharedAccounts?.()?.activate(harnessId, accountId)) return
      return accounts.activateAccount(harnessId, accountId)
    },
    removeAccount: async (accountId) => {
      if (await config.sharedAccounts?.()?.logout(accountId)) return
      return accounts.removeAccount(accountId)
    },
    accounts: async (harnessId, shared = false) => {
      if (harnessId === "grok-build") {
        let rows = await run(config.db.listHarnessAccounts(harnessId))
        if (!rows.length)
          rows = [
            await run(
              config.db.saveHarnessAccount({
                harnessId,
                profileKind: "default",
                label: "Grok",
                authState: "unauthenticated",
                canLogin: true,
                canLogout: false
              })
            )
          ]
        return Promise.all(rows.map((row) => grok.account(row, shared)))
      }
      return (
        (await config.sharedAccounts?.()?.accounts(harnessId)) ??
        (await run(config.db.listHarnessAccounts(harnessId))).map(core.publicAccount)
      )
    },
    probeAccount,
    accountContext: async (accountId) => {
      const shared = await config.sharedAccounts?.()?.context(accountId)
      if (shared !== undefined) {
        if (shared.env?.CLAUDE_CONFIG_DIR) await core.prepareClaudeStorage()
        return shared
      }
      const state = await probeAccount(accountId)
      if (state.authState !== "authenticated" && state.authState !== "notRequired") {
        throw new Error("Harness account requires sign-in")
      }
      const account = await run(config.db.getHarnessAccount(accountId))
      if (account === undefined) throw new Error(`Harness account not found: ${accountId}`)
      return contextFor(account)
    },
    activeAccountContext: async (harnessId) => {
      const accounts = await run(config.db.listHarnessAccounts(harnessId))
      const account = accounts.find((candidate) => candidate.isActive) ?? accounts[0]
      if (account === undefined) return undefined
      const shared = await config.sharedAccounts?.()?.context(account.id)
      if (shared !== undefined) {
        if (shared.env?.CLAUDE_CONFIG_DIR) await core.prepareClaudeStorage()
        return shared
      }
      const state = await probeAccount(account.id)
      return state.authState === "authenticated" || state.authState === "notRequired"
        ? contextFor(account)
        : undefined
    },
    markAccountExpired: async (accountId, detail) => {
      const account = await run(config.db.getHarnessAccount(accountId))
      if (account === undefined) return
      await persistProbe(account, {
        authState: "expired",
        canLogin: true,
        canLogout: account.canLogout,
        detail: detail ?? "Sign-in expired. Sign in again to continue."
      })
    },
    piProviders: async () => {
      const providers = await piAuth.providers()
      const configured = (await config.sharedProviders?.()?.configured("pi", "default")) ?? []
      const disabled = (await config.sharedProviders?.()?.disabled?.("pi", "default")) ?? []
      return providers.map((provider) => {
        if (configured.includes(provider.id))
          return { ...provider, credentialType: "oauth" as const }
        if (provider.credentialType === "oauth" && disabled.includes(provider.id)) {
          const { credentialType: _, ...unsigned } = provider
          return unsigned
        }
        return provider
      })
    },
    beginPiLogin: piAuth.beginLogin,
    piLoginFlow: piAuth.flow,
    answerPiLogin: piAuth.answer,
    cancelPiLogin: piAuth.cancel,
    logoutPiProvider: async (id) => {
      if (!(await config.sharedProviders?.()?.remove("pi", "default", id))) await piAuth.logout(id)
    },
    openCodeProviders: async (accountId) => {
      const providers = await openCodeAuth.providers(accountId)
      const configured = (await config.sharedProviders?.()?.configured("opencode", accountId)) ?? []
      const disabled = (await config.sharedProviders?.()?.disabled?.("opencode", accountId)) ?? []
      return providers.map((provider) => {
        if (configured.includes(provider.id))
          return { ...provider, credentialType: "oauth" as const }
        if (provider.credentialType === "oauth" && disabled.includes(provider.id)) {
          const { credentialType: _, ...unsigned } = provider
          return unsigned
        }
        return provider
      })
    },
    beginOpenCodeLogin: openCodeAuth.beginLogin,
    openCodeLoginFlow: openCodeAuth.flow,
    answerOpenCodeLogin: openCodeAuth.answer,
    cancelOpenCodeLogin: openCodeAuth.cancel,
    logoutOpenCodeProvider: async (accountId, id) => {
      if (!(await config.sharedProviders?.()?.remove("opencode", accountId, id)))
        await openCodeAuth.logout(accountId, id)
    },
    subscribe: (listener) => {
      listeners.add(listener)
      return () => listeners.delete(listener)
    }
  }
}
