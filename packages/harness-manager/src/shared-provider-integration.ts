import type { HarnessAccountContext } from "@codevisor/agent-runtime"
import type { HarnessAccount } from "@codevisor/api"

import type { ProviderOAuthHarness } from "./shared-provider-oauth.js"

export interface SharedProviderIntegration {
  readonly account?: (account: HarnessAccount, shared?: boolean) => Promise<HarnessAccount>
  readonly capture: (
    harness: ProviderOAuthHarness,
    profile: string,
    provider: string,
    credential: unknown,
    shared?: boolean
  ) => Promise<boolean>
  readonly configured: (
    harness: ProviderOAuthHarness,
    profile: string,
    shared?: boolean
  ) => Promise<ReadonlyArray<string>>
  readonly disabled?: (
    harness: ProviderOAuthHarness,
    profile: string
  ) => Promise<ReadonlyArray<string>>
  readonly remove: (
    harness: ProviderOAuthHarness,
    profile: string,
    provider: string,
    shared?: boolean
  ) => Promise<boolean>
  readonly context: (
    account: HarnessAccount,
    base: HarnessAccountContext
  ) => Promise<HarnessAccountContext>
}
