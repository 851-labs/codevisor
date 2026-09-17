import type { HarnessAccount } from "@codevisor/api"
import type { HarnessAccountContext } from "@codevisor/agent-runtime"

export interface SharedAccountIntegration {
  readonly reconcile: () => Promise<void>
  readonly probe: (id: string) => Promise<HarnessAccount | undefined>
  readonly context: (id: string) => Promise<HarnessAccountContext | undefined>
  readonly activate: (harnessId: string, id: string) => Promise<boolean>
  readonly accounts: (harnessId: string) => Promise<ReadonlyArray<HarnessAccount> | undefined>
  readonly captureLogin: (id: string) => Promise<void>
  readonly prepareLogin: (id: string, method?: string) => Promise<string>
  readonly logout: (id: string) => Promise<HarnessAccount | undefined>
  readonly loginFailed: (id: string) => Promise<void>
  readonly saveApiKey: (id: string, key: string) => Promise<void>
}
