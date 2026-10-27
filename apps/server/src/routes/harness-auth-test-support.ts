import type { HarnessAuth, HarnessAuthState } from "@codevisor/api"
import type { HarnessAuthManager, HarnessLifecycleManager } from "@codevisor/harness-manager"
import { vi } from "vitest"

import { field, itemsOf } from "./response-test-support.js"

const unused = (): never => {
  throw new Error("unused")
}

export const authStatus = (state: HarnessAuthState, detail?: string): HarnessAuth => ({
  state,
  accounts: [],
  loginMethods: [],
  supportsMultipleAccounts: false,
  ...(detail === undefined ? {} : { detail })
})

export const syncRows = (body: unknown, key: string): ReadonlyArray<unknown> =>
  itemsOf(field(body, "entries")).flatMap((entry) => itemsOf(field(field(entry, "value"), key)))

export const rowWithId = (rows: ReadonlyArray<unknown>, id: string): unknown =>
  rows.find((row) => field(row, "id") === id)

export const fakeHarnessAuth = (
  overrides: Partial<HarnessAuthManager> = {}
): HarnessAuthManager => ({
  decorateHarnesses: unused,
  decorateHarnessesFromStoredState: unused,
  refresh: unused,
  accounts: unused,
  createAccount: unused,
  renameAccount: unused,
  removeAccount: unused,
  activateAccount: unused,
  probeAccount: unused,
  beginLogin: unused,
  cancelLogin: unused,
  answerLogin: unused,
  logout: unused,
  accountContext: unused,
  activeAccountContext: unused,
  markAccountExpired: unused,
  subscribe: unused,
  ...overrides
})

export const fakeHarnessLifecycle = (
  overrides: Partial<HarnessLifecycleManager> = {}
): HarnessLifecycleManager => ({
  beginUninstall: unused,
  decorateHarnesses: unused,
  checkForUpdates: unused,
  startPeriodicChecks: unused,
  beginInstall: unused,
  prepareUpdate: unused,
  applyUpdate: unused,
  cancelUpdate: unused,
  notifyTurnStarted: unused,
  notifyTurnEnded: unused,
  isGated: unused,
  bundledAppInfo: unused,
  beginBundledAppUpdate: unused,
  finishPendingSetup: unused,
  onGateReleased: unused,
  subscribe: unused,
  ...overrides
})

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
