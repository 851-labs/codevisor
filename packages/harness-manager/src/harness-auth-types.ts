import type { spawnClaudeAuthClient } from "@codevisor/adapter-claude"
import type {
  makeOpenCode2Accounts,
  makeOpenCode2Logins,
  startOpenCodeServer
} from "@codevisor/adapter-opencode"
import type { AgentRuntimeService, HarnessAccountContext } from "@codevisor/agent-runtime"
import type {
  Harness,
  HarnessAccount,
  HarnessAuthFlow,
  OpenCodeAuthFlow,
  OpenCodeAuthProvider,
  PiAuthMethod,
  PiAuthProvider,
  PiAuthProviderFlow
} from "@codevisor/api"
import type { CodevisorDatabaseService } from "@codevisor/db"
import type { TerminalManagerService } from "@codevisor/terminal"
import type { OAuthAuth } from "@earendil-works/pi-ai"

import type { CredentialSource } from "./credential-ferry.js"
import type { SharedAccountIntegration } from "./shared-account-integration.js"
import type { SharedProviderIntegration } from "./shared-provider-integration.js"

export interface HarnessAuthExecOptions {
  readonly cwd?: string
  readonly env?: NodeJS.ProcessEnv
  readonly timeout?: number
  readonly maxBuffer?: number
  readonly input?: string
}

export type HarnessAuthExec = (
  command: string,
  args: ReadonlyArray<string>,
  options: HarnessAuthExecOptions
) => Promise<{ readonly stdout: string; readonly stderr: string }>

export type AuthEventKind =
  | "harness.auth.updated"
  | "harness.account.updated"
  | "harness.authFlow.updated"

export interface HarnessAuthEvent {
  readonly kind: AuthEventKind
  readonly subjectId: string
  readonly payload: unknown
}

export interface HarnessAuthManagerConfig {
  readonly sharedAccounts?: () => SharedAccountIntegration | undefined
  readonly sharedProviders?: () => SharedProviderIntegration | undefined
  readonly dataDir: string
  readonly db: CodevisorDatabaseService
  readonly agents: AgentRuntimeService
  readonly terminal: TerminalManagerService
  readonly preferDeviceCode?: boolean
  readonly grokOAuth?: OAuthAuth
  readonly claudeAuth?: typeof spawnClaudeAuthClient
  readonly resolveEnv?: () => Promise<NodeJS.ProcessEnv>
  readonly execFile?: HarnessAuthExec
  readonly openCode?: {
    readonly majorVersion?: (command: string) => Promise<number | undefined>
    readonly locate?: (env: NodeJS.ProcessEnv) => string | undefined
    readonly accounts?: Pick<
      ReturnType<typeof makeOpenCode2Accounts>,
      "providers" | "hold" | "removeIntegration"
    >
    readonly start?: typeof startOpenCodeServer
    readonly logins?: ReturnType<typeof makeOpenCode2Logins>
  }
}

export type HarnessAuthRefresh = "passive" | "force" | "settle"

export interface HarnessAuthManager {
  readonly sharedOpenCodeProfiles?: (content?: string) => Promise<ReadonlyArray<CredentialSource>>
  readonly decorateHarnesses: (
    harnesses: ReadonlyArray<Harness>,
    refresh?: HarnessAuthRefresh
  ) => Promise<ReadonlyArray<Harness>>
  readonly decorateHarnessesFromStoredState: (
    harnesses: ReadonlyArray<Harness>
  ) => Promise<ReadonlyArray<Harness>>
  readonly refresh: (harnessId?: string) => Promise<void>
  readonly accounts: (harnessId: string, shared?: boolean) => Promise<ReadonlyArray<HarnessAccount>>
  readonly createAccount: (harnessId: string, label?: string) => Promise<HarnessAccount>
  readonly renameAccount: (accountId: string, label: string) => Promise<HarnessAccount>
  readonly removeAccount: (accountId: string) => Promise<void>
  readonly activateAccount: (harnessId: string, accountId: string) => Promise<void>
  readonly probeAccount: (
    accountId: string,
    force?: boolean,
    shared?: boolean
  ) => Promise<HarnessAccount>
  readonly beginLogin: (
    accountId: string,
    methodId?: string,
    apiKey?: string,
    shared?: boolean
  ) => Promise<HarnessAuthFlow>
  readonly cancelLogin: (flowId: string) => Promise<void>
  readonly answerLogin: (flowId: string, code: string) => Promise<HarnessAuthFlow>
  readonly logout: (accountId: string, shared?: boolean) => Promise<HarnessAccount>
  readonly accountContext: (accountId: string) => Promise<HarnessAccountContext>
  readonly activeAccountContext: (harnessId: string) => Promise<HarnessAccountContext | undefined>
  readonly markAccountExpired: (accountId: string, detail?: string) => Promise<void>
  readonly piProviders?: () => Promise<ReadonlyArray<PiAuthProvider>>
  readonly beginPiLogin?: (
    providerId: string,
    method: PiAuthMethod,
    shared?: boolean
  ) => Promise<PiAuthProviderFlow>
  readonly piLoginFlow?: (flowId: string) => PiAuthProviderFlow
  readonly answerPiLogin?: (flowId: string, value: string) => Promise<PiAuthProviderFlow>
  readonly cancelPiLogin?: (flowId: string) => void
  readonly logoutPiProvider?: (providerId: string) => Promise<void>
  readonly openCodeProviders?: (
    accountId: string,
    shared?: boolean
  ) => Promise<ReadonlyArray<OpenCodeAuthProvider>>
  readonly beginOpenCodeLogin?: (
    accountId: string,
    providerId: string,
    methodId: string,
    inputs?: Readonly<Record<string, string>>,
    apiKey?: string,
    shared?: boolean
  ) => Promise<OpenCodeAuthFlow>
  readonly openCodeLoginFlow?: (flowId: string) => OpenCodeAuthFlow
  readonly answerOpenCodeLogin?: (flowId: string, code: string) => Promise<OpenCodeAuthFlow>
  readonly cancelOpenCodeLogin?: (flowId: string) => void
  readonly logoutOpenCodeProvider?: (accountId: string, providerId: string) => Promise<void>
  readonly subscribe: (listener: (event: HarnessAuthEvent) => void) => () => void
}
