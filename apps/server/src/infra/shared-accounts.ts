import { resolveShellEnv } from "@codevisor/agent-runtime"
import type { CodevisorDatabaseService } from "@codevisor/db"
import type { HarnessAuthManager, SharedCredentialVault } from "@codevisor/harness-manager"

import type { MachineClaudeLogin } from "./claude-login-takeover.js"
import { makeSharedAccountCredentials } from "./shared-account-credentials.js"
import { makeSharedAccountImports } from "./shared-account-imports.js"
import { makeSharedAccountLifecycle } from "./shared-account-lifecycle.js"
import { makeLocalAccountRows } from "./shared-account-local-rows.js"
import { SharedAccountLocalState } from "./shared-account-local-state.js"
import {
  makeClaudeProfileLogins,
  type ForgetProfileLogin
} from "./shared-account-profile-logins.js"
import { makeSharedAccountReconcile } from "./shared-account-reconcile.js"
import { makeSharedAccountRoster } from "./shared-account-roster.js"
import {
  discoverNativeAccount,
  forgetNativeProfileLogin,
  nativeClaudeMachine,
  sharedAccountVault
} from "./shared-account-storage.js"
import { makeSharedAccountStore } from "./shared-account-store.js"
import { makeSharedClaudeGateway } from "./shared-claude-gateway.js"
import { makeSharedProviderAccounts } from "./shared-provider-accounts.js"
import type { OpenCode2Deps } from "./shared-provider-opencode2.js"

export interface SharedAccountsOptions {
  readonly db: CodevisorDatabaseService
  readonly auth: HarnessAuthManager
  readonly dataDir: string
  readonly serverId: string
  readonly baseUrl: string
  readonly vault?: SharedCredentialVault
  readonly environment?: () => Promise<NodeJS.ProcessEnv>
  readonly discover?: typeof discoverNativeAccount
  readonly forgetProfileLogin?: ForgetProfileLogin
  readonly claudeMachine?: (env: NodeJS.ProcessEnv) => MachineClaudeLogin
  readonly openCode2?: OpenCode2Deps
}

export const makeSharedAccounts = (options: SharedAccountsOptions) => {
  const { db, auth, dataDir, serverId } = options
  const store = makeSharedAccountStore(db, serverId)
  const vault = options.vault ?? sharedAccountVault(dataDir)
  const environment = options.environment ?? resolveShellEnv
  const providers = makeSharedProviderAccounts({ ...options, store, vault, environment })
  const discover = options.discover ?? discoverNativeAccount
  const claudeMachine = options.claudeMachine ?? nativeClaudeMachine(dataDir)
  const localState = new SharedAccountLocalState(db, serverId)
  const profileLogins = makeClaudeProfileLogins({
    db,
    dataDir,
    localState,
    environment,
    forget: options.forgetProfileLogin ?? forgetNativeProfileLogin
  })

  const credentials = makeSharedAccountCredentials({ db, store, vault, localState })
  const gateway = makeSharedClaudeGateway({ token: credentials.token })
  const localRows = makeLocalAccountRows({ db, store, localState })
  const imports = makeSharedAccountImports({
    db,
    store,
    vault,
    localState,
    localRows,
    profileLogins,
    dataDir,
    serverId,
    environment,
    discover,
    claudeMachine,
    probe: credentials.probe
  })
  const reconcile = makeSharedAccountReconcile({
    db,
    store,
    localState,
    localRows,
    imports,
    profileLogins,
    providers,
    environment,
    discover
  })
  const roster = makeSharedAccountRoster({
    db,
    store,
    vault,
    localState,
    localRows,
    credentials,
    reconcile
  })
  const lifecycle = makeSharedAccountLifecycle({
    db,
    auth,
    store,
    vault,
    localState,
    localRows,
    credentials,
    profileLogins,
    gateway,
    dataDir,
    environment,
    options
  })

  return {
    store,
    providers,
    reconcile,
    reconcileRemote: async (): Promise<void> => {
      vault.invalidate()
      await reconcile()
    },
    probe: credentials.probe,
    accounts: roster.accounts,
    storedAccounts: roster.storedAccounts,
    activate: roster.activate,
    gateway,
    subscribe: store.subscribe,
    create: lifecycle.create,
    saveApiKey: imports.saveApiKey,
    prepareLogin: lifecycle.prepareLogin,
    loginFailed: lifecycle.loginFailed,
    notice: imports.takeover.notice,
    subscribeNotices: imports.takeover.subscribe,
    captureLogin: imports.captureLogin,
    context: lifecycle.context,
    logout: lifecycle.logout,
    rename: lifecycle.rename,
    inherit: roster.inherit
  }
}

export type SharedAccounts = ReturnType<typeof makeSharedAccounts>
