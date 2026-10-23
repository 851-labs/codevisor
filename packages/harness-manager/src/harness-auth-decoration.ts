import type { Harness, HarnessAuth, HarnessAuthMethod } from "@codevisor/api"
import type { HarnessAccountRecord } from "@codevisor/db"

import type { HarnessAuthCore } from "./harness-auth-core.js"
import type { HarnessAuthProbes } from "./harness-auth-probes.js"
import { run } from "./harness-auth-support.js"
import type { HarnessAuthManager, HarnessAuthRefresh } from "./harness-auth-types.js"

export type HarnessAuthDecoration = Pick<
  HarnessAuthManager,
  "decorateHarnesses" | "decorateHarnessesFromStoredState" | "refresh"
> & {
  readonly authSnapshot: (harnessId: string) => Promise<HarnessAuth>
}

const defaultAccountLabel = (harness: Harness): string => {
  if (harness.id === "pi") return "Pi configuration"
  if (harness.id === "opencode") return "Existing OpenCode profile"
  return `Existing ${harness.name} account`
}

export const makeHarnessAuthDecoration = (
  core: HarnessAuthCore,
  probes: HarnessAuthProbes
): HarnessAuthDecoration => {
  const { acpLoginMethods, catalog, config, persistProbe, publicAccount, refreshes } = core
  const { probeAccount } = probes

  const ensureDefault = async (harness: Harness): Promise<HarnessAccountRecord> => {
    const existing = (await run(config.db.listHarnessAccounts(harness.id))).find(
      (account) => account.profileKind === "default"
    )
    if (existing !== undefined) return existing
    return run(
      config.db.saveHarnessAccount({
        harnessId: harness.id,
        profileKind: "default",
        label: defaultAccountLabel(harness),
        authState: "checking",
        canLogin:
          harness.id === "codex" ||
          harness.id === "claude-code" ||
          harness.id === "cursor" ||
          harness.id === "pi" ||
          harness.id === "opencode" ||
          harness.id === "muse-code",
        canLogout: false
      })
    )
  }

  const loginMethods = (harnessId: string): ReadonlyArray<HarnessAuthMethod> => {
    if (harnessId === "codex") {
      const methods: ReadonlyArray<HarnessAuthMethod> = [
        {
          id: "chatgpt",
          name: "Sign in with ChatGPT",
          kind: "browser",
          description: "Continue in your web browser."
        },
        {
          id: "chatgptDeviceCode",
          name: "Sign in with a code",
          kind: "deviceCode",
          description: "Best for a remote Codevisor server."
        },
        {
          id: "apiKey",
          name: "Sign in with OpenAI API Key",
          kind: "apiKey",
          description: "Use API billing instead of a ChatGPT subscription."
        }
      ]
      return config.preferDeviceCode === true
        ? methods.filter((method) => method.id !== "chatgpt")
        : methods
    }
    if (harnessId === "claude-code") {
      return [
        {
          id: "claude-login",
          name: "Sign in to Claude",
          kind: "browser",
          description: "Approve in your browser, then paste the code back here."
        },
        {
          id: "apiKey",
          name: "Sign in with Anthropic API Key",
          kind: "apiKey",
          description: "Use Anthropic API billing instead of a Claude subscription."
        }
      ]
    }
    if (harnessId === "cursor") {
      return [
        {
          id: "cursor-login",
          name: "Sign in to Cursor",
          kind: "browser",
          description: "Continue in your web browser."
        }
      ]
    }
    if (harnessId === "grok-build")
      return [
        { id: "grok.com", name: "Sign in to Grok", kind: "deviceCode" },
        {
          id: "apiKey",
          name: "Use xAI API Key",
          kind: "apiKey",
          description: "Use xAI API billing."
        }
      ]
    if (harnessId === "muse-code")
      return [
        {
          id: "deviceCode",
          name: "Sign in with Meta",
          kind: "deviceCode",
          description: "Confirm a code in your browser."
        },
        {
          id: "apiKey",
          name: "Use a Meta API Key",
          kind: "apiKey",
          description: "Use Meta API billing instead of a Muse subscription."
        }
      ]
    if (harnessId === "antigravity")
      return [
        {
          id: "google",
          name: "Sign in with Google",
          kind: "browser",
          description: "Approve in your browser, then paste the code back here."
        },
        {
          id: "apiKey",
          name: "Use a Gemini API Key",
          kind: "apiKey",
          description: "Use Gemini API billing instead of an Antigravity plan."
        }
      ]
    if (harnessId === "pi") return []
    return acpLoginMethods.get(harnessId) ?? []
  }

  const authSnapshot = async (harnessId: string): Promise<HarnessAuth> => {
    const storedAccounts = await config.sharedAccounts?.()?.storedAccounts?.(harnessId)
    const accounts =
      storedAccounts ?? (await run(config.db.listHarnessAccounts(harnessId))).map(publicAccount)
    const active = accounts.find((account) => account.isActive) ?? accounts[0]
    const notice = await config.sharedAccounts?.()?.notice?.(harnessId)
    return {
      state:
        active?.authState ?? (storedAccounts === undefined ? "unavailable" : "unauthenticated"),
      ...(active === undefined ? {} : { activeAccountId: active.id }),
      ...(active?.detail ? { detail: active.detail } : {}),
      accounts,
      loginMethods: loginMethods(harnessId),
      supportsMultipleAccounts: [
        "codex",
        "claude-code",
        "opencode",
        "muse-code",
        "antigravity"
      ].includes(harnessId),
      ...(notice === undefined ? {} : { notice })
    }
  }

  const refreshAccount = (account: HarnessAccountRecord, force: boolean): Promise<void> => {
    const current = refreshes.get(account.id)
    if (current !== undefined) return current
    const pending = (async () => {
      try {
        await probeAccount(account.id, force)
      } catch (cause) {
        await persistProbe(account, {
          authState: "error",
          canLogin: account.canLogin,
          canLogout: false,
          detail: cause instanceof Error ? cause.message : String(cause)
        })
      }
    })().finally(() => refreshes.delete(account.id))
    refreshes.set(account.id, pending)
    return pending
  }

  const refresh = async (harnessId?: string): Promise<void> => {
    const ids = harnessId === undefined ? catalog.map((entry) => entry.id) : [harnessId]
    await Promise.all(
      ids.map(async (id) => {
        const accounts = await run(config.db.listHarnessAccounts(id))
        await Promise.all(accounts.map((account) => refreshAccount(account, true)))
      })
    )
  }

  const decorateHarnessesWithMode = async (
    harnesses: ReadonlyArray<Harness>,
    mode: HarnessAuthRefresh | "stored"
  ): Promise<ReadonlyArray<Harness>> =>
    Promise.all(
      harnesses.map(async (harness) => {
        const desiredEnabled = harness.desiredEnabled ?? harness.enabled
        if (harness.readiness.state !== "ready") {
          return { ...harness, desiredEnabled, enabled: false }
        }
        const fallback = await ensureDefault(harness)
        const account =
          (await run(config.db.listHarnessAccounts(harness.id))).find((row) => row.isActive) ??
          fallback
        if (mode === "force") {
          await refreshAccount(account, true)
        } else if (mode === "settle") {
          await refreshAccount(account, false)
        } else if (mode === "passive") {
          void refreshAccount(account, false).catch(() => undefined)
        }
        const auth = await authSnapshot(harness.id)
        const usable = auth.state === "authenticated" || auth.state === "notRequired"
        return { ...harness, desiredEnabled, enabled: desiredEnabled && usable, auth }
      })
    )

  return {
    authSnapshot,
    decorateHarnesses: (harnesses, authRefresh = "passive") =>
      decorateHarnessesWithMode(harnesses, authRefresh),
    decorateHarnessesFromStoredState: (harnesses) => decorateHarnessesWithMode(harnesses, "stored"),
    refresh
  }
}
