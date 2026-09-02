import { makeHarnessAccountOperations } from "./harness-auth-accounts.js"
import { makeHarnessAuthCore } from "./harness-auth-core.js"
import { makeHarnessAuthDecoration } from "./harness-auth-decoration.js"
import { makeHarnessLoginOperations } from "./harness-auth-logins.js"
import { makeHarnessAuthProbes } from "./harness-auth-probes.js"
import { run } from "./harness-auth-support.js"
import type { HarnessAuthManager, HarnessAuthManagerConfig } from "./harness-auth-types.js"
import { makeOpenCodeAuthManager, openCodeAuthPath } from "./opencode-auth.js"
import { makePiAuthManager } from "./pi-auth.js"

export type {
  HarnessAuthEvent,
  HarnessAuthManager,
  HarnessAuthManagerConfig
} from "./harness-auth-types.js"

export const makeHarnessAuthManager = (config: HarnessAuthManagerConfig): HarnessAuthManager => {
  const core = makeHarnessAuthCore(config)
  const { accountEnv, contextFor, environment, executable, listeners, persistProbe, profilePath } =
    core
  const piAuth = makePiAuthManager({ resolveEnv: environment })
  const openCodeAuth = makeOpenCodeAuthManager({
    profile: async (accountId) => {
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
  })
  const probes = makeHarnessAuthProbes(core)
  const { probeAccount } = probes
  const decoration = makeHarnessAuthDecoration(core, probes)
  const accounts = makeHarnessAccountOperations(core, probes, decoration)
  const logins = makeHarnessLoginOperations(core, probes)

  return {
    decorateHarnesses: decoration.decorateHarnesses,
    decorateHarnessesFromStoredState: decoration.decorateHarnessesFromStoredState,
    refresh: decoration.refresh,
    ...accounts,
    ...logins,
    accounts: async (harnessId) =>
      (await run(config.db.listHarnessAccounts(harnessId))).map(core.publicAccount),
    probeAccount,
    accountContext: async (accountId) => {
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
    piProviders: piAuth.providers,
    beginPiLogin: piAuth.beginLogin,
    piLoginFlow: piAuth.flow,
    answerPiLogin: piAuth.answer,
    cancelPiLogin: piAuth.cancel,
    logoutPiProvider: piAuth.logout,
    openCodeProviders: openCodeAuth.providers,
    beginOpenCodeLogin: openCodeAuth.beginLogin,
    openCodeLoginFlow: openCodeAuth.flow,
    answerOpenCodeLogin: openCodeAuth.answer,
    cancelOpenCodeLogin: openCodeAuth.cancel,
    logoutOpenCodeProvider: openCodeAuth.logout,
    subscribe: (listener) => {
      listeners.add(listener)
      return () => listeners.delete(listener)
    }
  }
}
