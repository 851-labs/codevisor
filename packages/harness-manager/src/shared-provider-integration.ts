import type { HarnessAccountContext } from "@codevisor/agent-runtime"
import type { HarnessAccount, OpenCodeAuthFlow, OpenCodeAuthProvider } from "@codevisor/api"

import type { ProviderOAuthHarness } from "./shared-provider-oauth.js"

export interface ClaudeAgentIntegration {
  readonly provider: (
    profile: string,
    listed: OpenCodeAuthProvider
  ) => Promise<OpenCodeAuthProvider>
  readonly begin: (
    profile: string,
    inputs: Readonly<Record<string, string>> | undefined
  ) => Promise<OpenCodeAuthFlow>
  readonly flow: (flowId: string) => OpenCodeAuthFlow | undefined
  readonly answer: (flowId: string, code: string) => Promise<OpenCodeAuthFlow | undefined>
  readonly cancel: (flowId: string) => Promise<void>
}

export interface SharedProviderIntegration {
  readonly claudeAgent?: ClaudeAgentIntegration
  readonly account?: (account: HarnessAccount) => Promise<HarnessAccount>
  readonly capture: (
    harness: ProviderOAuthHarness,
    profile: string,
    provider: string,
    credential: unknown
  ) => Promise<boolean>
  readonly configured: (
    harness: ProviderOAuthHarness,
    profile: string
  ) => Promise<ReadonlyArray<string>>
  readonly disabled?: (
    harness: ProviderOAuthHarness,
    profile: string
  ) => Promise<ReadonlyArray<string>>
  readonly remove: (
    harness: ProviderOAuthHarness,
    profile: string,
    provider: string
  ) => Promise<boolean>
  readonly context: (
    account: HarnessAccount,
    base: HarnessAccountContext
  ) => Promise<HarnessAccountContext>
}
