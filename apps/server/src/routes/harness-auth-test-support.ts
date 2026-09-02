import type { HarnessAuthManager } from "@codevisor/harness-manager"
import { vi } from "vitest"

/// A scripted HarnessAuthManager for the harness route tests: one default
/// account, a Pi provider flow, OpenCode provider flows, and a mutable
/// `state` the tests flip to simulate sign-out and missing account context.
export const makeAuthFixture = () => {
  const account = {
    id: "account-1",
    harnessId: "codex",
    profileKind: "default" as const,
    label: "person@example.com",
    email: "person@example.com",
    authState: "authenticated" as const,
    isActive: true,
    canLogin: true,
    canLogout: true
  }
  const accountList = [account]
  const piProvider = { id: "openai", name: "OpenAI", methods: ["api_key" as const] }
  const piFlow = {
    id: "pi-flow-1",
    providerId: piProvider.id,
    state: "waiting" as const,
    prompt: {
      id: "api-key",
      type: "secret" as const,
      message: "Enter OpenAI API key",
      options: []
    }
  }
  const state: {
    authState: "authenticated" | "unauthenticated"
    activeContextAvailable: boolean
  } = { authState: "authenticated", activeContextAvailable: true }
  const auth: HarnessAuthManager = {
    answerLogin: () => Promise.reject(new Error("unused")),
    decorateHarnesses: async (values) =>
      values.map((harness) => {
        const desiredEnabled = harness.enabled
        return {
          ...harness,
          desiredEnabled,
          enabled: desiredEnabled && state.authState === "authenticated",
          auth: {
            state: state.authState,
            activeAccountId: account.id,
            accounts: accountList,
            loginMethods: [{ id: "browser", name: "Browser", kind: "browser" }],
            supportsMultipleAccounts: true
          }
        }
      }),
    decorateHarnessesFromStoredState: async (values) => auth.decorateHarnesses(values),
    refresh: vi.fn(async () => undefined),
    accounts: vi.fn(async () => accountList),
    createAccount: vi.fn(async () => account),
    renameAccount: vi.fn(async () => account),
    removeAccount: vi.fn(async () => undefined),
    activateAccount: vi.fn(async () => undefined),
    probeAccount: vi.fn(async () => account),
    beginLogin: vi.fn(async () => ({
      id: "flow-1",
      accountId: account.id,
      kind: "complete" as const
    })),
    cancelLogin: vi.fn(async () => undefined),
    logout: vi.fn(async () => ({ ...account, authState: "unauthenticated" as const })),
    accountContext: vi.fn(async () => ({ id: account.id, profileKind: "default" as const })),
    activeAccountContext: vi.fn(async () =>
      state.activeContextAvailable ? { id: account.id, profileKind: "default" as const } : undefined
    ),
    markAccountExpired: vi.fn(async () => undefined),
    piProviders: vi.fn(async () => [piProvider]),
    beginPiLogin: vi.fn(async () => piFlow),
    piLoginFlow: vi.fn(() => piFlow),
    answerPiLogin: vi.fn(async () => ({ ...piFlow, state: "complete" as const })),
    cancelPiLogin: vi.fn(() => undefined),
    logoutPiProvider: vi.fn(async () => undefined),
    openCodeProviders: vi.fn(async () => [
      {
        id: "openai",
        name: "OpenAI",
        methods: [{ id: "0", type: "oauth" as const, label: "ChatGPT", prompts: [] }],
        credentialType: "oauth" as const
      }
    ]),
    beginOpenCodeLogin: vi.fn(async () => ({
      id: "flow-open",
      accountId: account.id,
      providerId: "openai",
      state: "waiting" as const,
      authorization: {
        url: "https://example.test/login",
        method: "code" as const,
        instructions: "Sign in"
      }
    })),
    openCodeLoginFlow: vi.fn(() => ({
      id: "flow-open",
      accountId: account.id,
      providerId: "openai",
      state: "waiting" as const
    })),
    answerOpenCodeLogin: vi.fn(async () => ({
      id: "flow-open",
      accountId: account.id,
      providerId: "openai",
      state: "complete" as const
    })),
    cancelOpenCodeLogin: vi.fn(() => undefined),
    logoutOpenCodeProvider: vi.fn(async () => undefined),
    subscribe: () => () => undefined
  }
  return { account, accountList, auth, piFlow, piProvider, state }
}
