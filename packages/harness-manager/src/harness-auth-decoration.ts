import type { Harness, HarnessAuth, HarnessAuthMethod } from "@codevisor/api"
import type { HarnessAccountRecord } from "@codevisor/db"
import type { HarnessAuthCore } from "./harness-auth-core.js"
import type { HarnessAuthProbes } from "./harness-auth-probes.js"
import { run } from "./harness-auth-support.js"
import type { HarnessAuthManager } from "./harness-auth-types.js"

export type HarnessAuthDecoration = Pick<
  HarnessAuthManager,
  "decorateHarnesses" | "decorateHarnessesFromStoredState" | "refresh"
> & {
  readonly authSnapshot: (harnessId: string) => Promise<HarnessAuth>
}

/// The auth view over discovered harnesses: login methods, the per-harness
/// snapshot, single-flight refreshes, and the decoration modes (passive,
/// forced, stored) the catalog and settings surfaces use.
export const makeHarnessAuthDecoration = (
  core: HarnessAuthCore,
  probes: HarnessAuthProbes
): HarnessAuthDecoration => {
  const { acpLoginMethods, catalogNow, config, persistProbe, publicAccount, refreshes } = core
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
        label:
          harness.id === "pi"
            ? "Pi configuration"
            : harness.id === "opencode"
              ? "Existing OpenCode profile"
              : `Existing ${harness.name} account`,
        authState: "checking",
        canLogin:
          harness.id === "codex" ||
          harness.id === "claude-code" ||
          harness.id === "pi" ||
          harness.id === "opencode",
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
      // Codex's ordinary browser handoff returns to the machine that launched
      // it, so it cannot complete through a remote Codevisor server. Remote
      // servers expose device code and API key only; both native clients get
      // the same honest method list from this snapshot.
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
    if (harnessId === "pi") return []
    return acpLoginMethods.get(harnessId) ?? []
  }

  const authSnapshot = async (harnessId: string): Promise<HarnessAuth> => {
    const accounts = (await run(config.db.listHarnessAccounts(harnessId))).map(publicAccount)
    const active = accounts.find((account) => account.isActive) ?? accounts[0]
    return {
      state: active?.authState ?? "unavailable",
      ...(active === undefined ? {} : { activeAccountId: active.id }),
      accounts,
      loginMethods: loginMethods(harnessId),
      supportsMultipleAccounts:
        harnessId === "codex" || harnessId === "claude-code" || harnessId === "opencode"
    }
  }

  const refreshAccount = (account: HarnessAccountRecord, force: boolean): Promise<void> => {
    const current = refreshes.get(account.id)
    if (current !== undefined) return current
    // Keep the failure write inside the single-flight boundary. Otherwise every
    // waiter on one failed probe persists the same error and emits another pair
    // of account/auth events.
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
    const ids = harnessId === undefined ? catalogNow().map((entry) => entry.id) : [harnessId]
    await Promise.all(
      ids.map(async (id) => {
        const accounts = await run(config.db.listHarnessAccounts(id))
        await Promise.all(accounts.map((account) => refreshAccount(account, true)))
      })
    )
  }

  const decorateHarnessesWithMode = async (
    harnesses: ReadonlyArray<Harness>,
    mode: "passive" | "force" | "stored"
  ): Promise<ReadonlyArray<Harness>> =>
    Promise.all(
      harnesses.map(async (harness) => {
        const desiredEnabled = harness.enabled
        if (harness.readiness.state !== "ready") {
          return { ...harness, desiredEnabled, enabled: false }
        }
        const account = await ensureDefault(harness)
        if (mode === "force") {
          await refreshAccount(account, true)
        } else if (mode === "passive") {
          // Capability discovery is latency-sensitive. Return the persisted
          // auth snapshot immediately and refresh it in the background; auth
          // events invalidate mounted catalogs when the probe finishes.
          void refreshAccount(account, false).catch(() => undefined)
        }
        const auth = await authSnapshot(harness.id)
        const usable = auth.state === "authenticated" || auth.state === "notRequired"
        return { ...harness, desiredEnabled, enabled: desiredEnabled && usable, auth }
      })
    )

  return {
    authSnapshot,
    decorateHarnesses: (harnesses, force = false) =>
      decorateHarnessesWithMode(harnesses, force ? "force" : "passive"),
    decorateHarnessesFromStoredState: (harnesses) => decorateHarnessesWithMode(harnesses, "stored"),
    refresh
  }
}
