import { randomUUID } from "node:crypto"
import { mkdir } from "node:fs/promises"
import { homedir } from "node:os"
import { join } from "node:path"

import { resolveShellEnv, type HarnessAccountContext } from "@codevisor/agent-runtime"
import { isoTimestamp, type HarnessAccount } from "@codevisor/api"
import type { CodevisorDatabaseService, HarnessAccountRecord } from "@codevisor/db"
import {
  SharedCredentialError,
  sharedApiKey,
  sharedOAuthIdentity
} from "@codevisor/harness-manager"
import type {
  HarnessAuthManager,
  SharedCredentialVault,
  SharedOAuthHarness,
  SharedTokenBundle
} from "@codevisor/harness-manager"
import { latestSyncTimestamp, nextSyncTimestamp } from "@codevisor/sync"
import { Effect } from "effect"

import { discoverNativeAccount, sharedAccountVault } from "./shared-account-storage.js"
import {
  makeSharedAccountStore,
  sharedHarness,
  type SharedHarnessAccount
} from "./shared-account-store.js"
import { makeSharedClaudeGateway } from "./shared-claude-gateway.js"
import { makeSharedProviderAccounts } from "./shared-provider-accounts.js"

const LOCAL = "local.shared-accounts"
const run = Effect.runPromise
const publicAccount = (record: HarnessAccountRecord): HarnessAccount => {
  const { profileKey: _key, createdAt: _created, updatedAt: _updated, ...account } = record
  return account
}

export const makeSharedAccounts = (options: {
  readonly db: CodevisorDatabaseService
  readonly auth: HarnessAuthManager
  readonly dataDir: string
  readonly serverId: string
  readonly baseUrl: string
  readonly vault?: SharedCredentialVault
  readonly environment?: () => Promise<NodeJS.ProcessEnv>
  readonly discover?: typeof discoverNativeAccount
}) => {
  const { db, auth, dataDir, serverId } = options
  const store = makeSharedAccountStore(db, serverId)
  const vault = options.vault ?? sharedAccountVault(dataDir)
  const environment = options.environment ?? resolveShellEnv
  const providers = makeSharedProviderAccounts({ ...options, store, vault, environment })
  const discover = options.discover ?? discoverNativeAccount
  const pending = new Set<string>()
  let reconciling: Promise<void> | undefined
  const local = async (key: string) =>
    (await run(db.getSyncEntries(LOCAL))).find((entry) => entry.key === key && !entry.deleted)
      ?.value
  const setLocal = async (key: string, value: unknown) =>
    run(
      db.mergeSyncEntries(LOCAL, [
        {
          key,
          value,
          timestamp: nextSyncTimestamp(
            serverId,
            latestSyncTimestamp(await run(db.getSyncEntries(LOCAL))),
            Date.now()
          )
        }
      ])
    )
  const resolve = async (id: string) => {
    const alias = await local(`alias:${id}`)
    return store.get(typeof alias === "string" ? alias : id)
  }
  const token = async (id: string, rejected?: string) => {
    const account = await resolve(id)
    if (!account?.credential || (await local(`disabled:${account.id}`)) === true)
      throw new SharedCredentialError("revoked")
    return vault.token(account.credential, rejected)
  }
  const gateway = makeSharedClaudeGateway({ token })
  const saveLocal = async (account: SharedHarnessAccount, adopted?: SharedTokenBundle) => {
    const existing = await run(db.getHarnessAccount(account.id))
    // A grant adopted from a live token is signed in now; seed the row so onboarding offers it.
    const live = adopted !== undefined && adopted.expiresAt > Date.now() + 30_000
    return run(
      db.saveHarnessAccount({
        id: account.id,
        harnessId: account.harnessId,
        profileKind: "managed",
        profileKey: account.id,
        label: account.label,
        ...(account.email ? { email: account.email } : {}),
        ...(account.organizationId ? { organizationId: account.organizationId } : {}),
        authMethod: existing?.authMethod ?? adopted?.authMethod ?? "oauth",
        authState: existing?.authState ?? (live ? "authenticated" : "checking"),
        canLogin: true,
        // The probe owns canLogout once a row exists; a machine sign-out keeps the grant.
        canLogout: existing?.canLogout ?? account.credential !== undefined,
        ...(existing?.detail ? { detail: existing.detail } : {})
      })
    )
  }
  const applySelection = async (harnessId: string) => {
    const selected = await store.selected(harnessId, true)
    if (!selected) return
    const rows = await run(db.listHarnessAccounts(harnessId))
    if (
      !rows.some((row) => row.id === selected) ||
      rows.some((row) => row.id === selected && row.isActive)
    )
      return
    await run(db.setActiveHarnessAccount(harnessId, selected))
    for (const previous of rows.filter(
      (row) =>
        row.id !== selected && (harnessId === "claude-code" || row.authState !== "authenticated")
    )) {
      if (harnessId === "codex" && (await local(`alias:${previous.id}`))) continue
      await run(db.rebindHarnessAccountSessions(previous.id, selected))
    }
  }
  const importBundle = async (
    bundle: SharedTokenBundle,
    nativeId?: string,
    explicit = false,
    label?: string
  ) => {
    const id = sharedOAuthIdentity(bundle)
    const previous = await store.get(id)
    // Isolated Codevisor profiles already belong to us. Adopt their grant
    // when upgrading an access-only mirror, without another sign-in.
    explicit ||= !!(
      bundle.refreshToken &&
      bundle.ownership === "managed" &&
      previous?.sourceMachineId
    )
    const tombstone = (await store.entries()).some((entry) => entry.key === id && entry.deleted)
    if (tombstone && !explicit) return
    if (previous?.credential && !explicit) {
      if (bundle.ownership === "external") await vault.publishExternal(previous.credential, bundle)
    } else {
      const credential = await vault.create(bundle)
      if (previous?.credential) await vault.revoke(previous.credential)
      // Publish only after the coordinator has durably stored the encrypted
      // grant. A synced reference must never point at a not-yet-created grant.
      await store.save({
        id,
        harnessId: bundle.harnessId,
        label:
          previous?.label ??
          (label && label !== "New Account" ? label : undefined) ??
          bundle.email ??
          (bundle.harnessId === "codex" ? "ChatGPT" : "Claude"),
        subject: bundle.subject,
        ...(bundle.email ? { email: bundle.email } : {}),
        ...(bundle.organizationId ? { organizationId: bundle.organizationId } : {}),
        createdAt: previous?.createdAt ?? Date.now(),
        credential,
        ...(bundle.ownership === "external"
          ? { sourceMachineId: serverId, sourceExpiresAt: bundle.expiresAt }
          : {})
      })
    }
    const saved = (await store.get(id))!
    await saveLocal(saved, previous?.credential && !explicit ? undefined : bundle)
    if (nativeId && nativeId !== id) {
      await setLocal(`alias:${nativeId}`, id)
      if (bundle.harnessId === "claude-code")
        await run(db.rebindHarnessAccountSessions(nativeId, id))
    }
    return saved
  }
  const nativeBundle = async (account: HarnessAccountRecord, managed: boolean) => {
    if (!sharedHarness(account.harnessId) || account.profileKind !== "managed") return undefined
    const path = join(
      dataDir,
      "harness-profiles",
      account.harnessId,
      account.profileKey ?? account.id
    )
    return discover(account.harnessId, path, false, managed, await environment())
  }

  const captureLogin = async (id: string) => {
    const row = await run(db.getHarnessAccount(id))
    const target = await local(`login:${id}`)
    if (!row || typeof target !== "string") return
    const bundle = await nativeBundle(row, true)
    if (!bundle?.refreshToken) throw new Error("Sign-in could not be saved. Try signing in again.")
    const account = (await importBundle(bundle, id, true, row.label))!
    if (
      target !== account.id &&
      target.startsWith("shared-") &&
      !(await store.get(target))?.credential
    )
      await store.remove(target)
    await setLocal(`alias:${target}`, account.id)
    await setLocal(`disabled:${account.id}`, false)
    pending.delete(id)
    await setLocal(`pending:${target}`, false)
    await applySelection(bundle.harnessId)
  }
  const reconcile = (): Promise<void> => {
    reconciling ??= (async () => {
      for (const harnessId of ["claude-code", "codex"] as const) {
        const env = await environment()
        const directory =
          harnessId === "codex"
            ? (env.CODEX_HOME ?? join(env.HOME ?? homedir(), ".codex"))
            : (env.CLAUDE_CONFIG_DIR ?? join(env.HOME ?? homedir(), ".claude"))
        // Discovery is independent for each provider. A locked Keychain or
        // corrupt external file must not block the other account's adoption.
        try {
          const bundle = await discover(harnessId, directory, true, false, env)
          const rows = await run(db.listHarnessAccounts(harnessId))
          if (bundle)
            await importBundle(bundle, rows.find((row) => row.profileKind === "default")?.id)
          for (const row of rows.filter(
            (row) =>
              row.profileKind === "managed" && !row.id.startsWith("shared-") && !pending.has(row.id)
          )) {
            if (await local(`alias:${row.id}`)) continue
            if (typeof (await local(`login:${row.id}`)) === "string") {
              const saved = await nativeBundle(row, true)
              if (saved?.refreshToken) await captureLogin(row.id)
              continue
            }
            const existing = await nativeBundle(row, true)
            if (existing) await importBundle(existing, row.id, false, row.label)
          }
        } catch {
          /* Existing local sign-in remains usable; shared state exposes its own errors below. */
        }
      }
      for (const account of await store.accounts()) await saveLocal(account)
      for (const harnessId of ["claude-code", "codex"]) await applySelection(harnessId)
      await providers.reconcile()
    })().finally(() => {
      reconciling = undefined
    })
    return reconciling
  }
  const probe = async (id: string, shared = false): Promise<HarnessAccount | undefined> => {
    if (pending.has(id)) return undefined
    if ((await local(`pending:${id}`)) === true) {
      const update = {
        authState: "checking" as const,
        canLogin: true,
        canLogout: false,
        detail: null
      }
      return publicAccount(await run(db.updateHarnessAccountAuth(id, update)))
    }
    const account = await resolve(id)
    const native = await run(db.getHarnessAccount(id))
    if (!account && native && !sharedHarness(native.harnessId)) return undefined
    if (!account && !id.startsWith("shared-")) return undefined
    let detail: string | null = null
    let authMethod: "oauth" | "apiKey" = "oauth"
    let authState: "authenticated" | "expired" | "unauthenticated" = "authenticated"
    try {
      const bundle =
        shared && account?.credential ? await vault.token(account.credential) : await token(id)
      authMethod = bundle.authMethod ?? "oauth"
    } catch (cause) {
      authState = account?.credential ? "expired" : "unauthenticated"
      detail =
        cause instanceof SharedCredentialError
          ? cause.message
          : "Account sync is unavailable. Try again."
    }
    const existing = await run(db.getHarnessAccount(id))
    if (!existing) return undefined
    if (shared) {
      const { detail: _detail, ...value } = publicAccount(existing)
      return {
        ...value,
        authState,
        authMethod,
        canLogin: true,
        canLogout: authState === "authenticated",
        ...(detail ? { detail } : {})
      }
    }
    return publicAccount(
      await run(
        db.updateHarnessAccountAuth(id, {
          authState,
          authMethod,
          detail,
          canLogin: true,
          canLogout: authState === "authenticated",
          lastCheckedAt: isoTimestamp()
        })
      )
    )
  }
  const storedAccounts = async (
    harnessId: SharedOAuthHarness
  ): Promise<ReadonlyArray<HarnessAccount>> => {
    const sharedIds = new Set((await store.accounts()).map((account) => account.id))
    const rows: HarnessAccount[] = []
    for (const row of await run(db.listHarnessAccounts(harnessId))) {
      if (row.id.startsWith("shared-")) {
        if (!sharedIds.has(row.id)) continue
      } else if (pending.has(row.id) || (await local(`alias:${row.id}`))) continue
      rows.push(publicAccount(row))
    }
    return rows
  }
  const accounts = async (
    harnessId: string,
    shared = false
  ): Promise<ReadonlyArray<HarnessAccount> | undefined> => {
    if (!sharedHarness(harnessId)) return undefined
    await reconcile()
    const selected = await store.selected(harnessId, !shared)
    const selectionScope =
      !shared &&
      ((await store.overridden(harnessId)) ||
        (selected && (await local(`disabled:${selected}`)) === true))
        ? "machine"
        : "shared"
    const rows: HarnessAccount[] = []
    for (const account of await store.accounts()) {
      if (account.harnessId !== harnessId) continue
      const value = await probe(account.id, shared)
      if (value) rows.push({ ...value, isActive: account.id === selected, selectionScope })
    }
    if (!shared)
      for (const row of await storedAccounts(harnessId)) {
        if (!row.id.startsWith("shared-")) rows.push(row)
      }
    return rows
  }
  const activate = async (harnessId: string, id: string, shared = false): Promise<boolean> => {
    const account = await resolve(id)
    if (!account) return false
    if (account.harnessId !== harnessId) throw new Error("Account belongs to another harness")
    if (!account.credential) throw new Error("Sign in to this account first")
    await vault.token(account.credential)
    await setLocal(`disabled:${account.id}`, false)
    if (!shared && account.id === (await store.selected(harnessId, false)))
      await store.inherit(harnessId)
    else await store.select(harnessId, account.id, !shared)
    await applySelection(harnessId)
    await probe(account.id)
    return true
  }
  const create = async (harnessId: SharedOAuthHarness, label?: string) => {
    const account: SharedHarnessAccount = {
      id: `shared-${randomUUID()}`,
      harnessId,
      label: label?.trim() || "New Account",
      createdAt: Date.now()
    }
    await store.save(account)
    return publicAccount(await saveLocal(account))
  }
  return {
    store,
    providers,
    reconcile,
    /// For changes that arrived from another machine through sync: held
    /// credentials may predate them (a global sign-out), so drop them first.
    /// The periodic sweep must not, or every read would go remote again.
    reconcileRemote: async (): Promise<void> => {
      vault.invalidate()
      await reconcile()
    },
    probe,
    accounts,
    storedAccounts: async (harnessId: string) =>
      sharedHarness(harnessId) ? storedAccounts(harnessId) : undefined,
    activate,
    gateway,
    subscribe: store.subscribe,
    create,
    saveApiKey: async (id: string, key: string): Promise<void> => {
      const row = await run(db.getHarnessAccount(id))
      if (!row || !sharedHarness(row.harnessId) || !key.trim()) throw new Error("Enter an API key")
      const account = (await importBundle(
        sharedApiKey(row.harnessId, key.trim()),
        id,
        true,
        row.label
      ))!
      if (id.startsWith("shared-") && account.id !== id && !(await store.get(id))?.credential)
        await store.remove(id)
      await applySelection(row.harnessId)
    },
    prepareLogin: async (id: string, method?: string): Promise<string> => {
      const row = await run(db.getHarnessAccount(id))
      if (!row || !sharedHarness(row.harnessId) || method === "apiKey") return id
      // Always use a fresh isolated profile for an OAuth grant we own. Never
      // acquire the refresh token of a user's independently running CLI.
      const fresh = await auth.createAccount(row.harnessId, row.label)
      pending.add(fresh.id)
      await setLocal(`login:${fresh.id}`, id)
      await setLocal(`pending:${id}`, true)
      return fresh.id
    },
    loginFailed: async (id: string) => {
      pending.delete(id)
      const target = await local(`login:${id}`)
      if (typeof target === "string") await setLocal(`pending:${target}`, false)
    },
    captureLogin,
    context: async (id: string): Promise<HarnessAccountContext | undefined> => {
      const account = await resolve(id)
      if (!account) {
        const native = await run(db.getHarnessAccount(id))
        if (id.startsWith("shared-") && (!native || sharedHarness(native.harnessId)))
          throw new SharedCredentialError("revoked")
        return undefined
      }
      const bundle = await token(id)
      let path = join(dataDir, "harness-profiles", account.harnessId, account.id)
      // Existing Codex threads stay in their original local profile. External
      // token mode changes authentication in memory without moving transcripts.
      if (account.harnessId === "codex" && id !== account.id) {
        const original = await run(db.getHarnessAccount(id))
        if (original?.profileKind === "managed")
          path = join(dataDir, "harness-profiles", "codex", original.profileKey ?? original.id)
        else if (original?.profileKind === "default") {
          const env = await environment()
          path = env.CODEX_HOME ?? join(env.HOME ?? homedir(), ".codex")
        }
      }
      await mkdir(path, { recursive: true, mode: 0o700 })
      if (bundle.authMethod === "apiKey")
        return {
          id: account.id,
          profileKind: "managed",
          profilePath: path,
          env:
            account.harnessId === "codex"
              ? { CODEX_HOME: path, OPENAI_API_KEY: bundle.accessToken }
              : { CLAUDE_CONFIG_DIR: path, ANTHROPIC_API_KEY: bundle.accessToken }
        }
      if (account.harnessId === "codex")
        return {
          id: account.id,
          profileKind: "managed",
          profilePath: path,
          env: { CODEX_HOME: path },
          oauth: {
            token: async (rejected) => {
              const current = await token(account.id, rejected)
              return {
                accessToken: current.accessToken,
                ...(current.organizationId ? { accountId: current.organizationId } : {}),
                ...(current.planType ? { planType: current.planType } : {})
              }
            }
          }
        }
      gateway.register(account.id, bundle.accessToken)
      return {
        id: account.id,
        profileKind: "managed",
        profilePath: path,
        env: {
          CLAUDE_CONFIG_DIR: path,
          CLAUDE_CODE_OAUTH_TOKEN: bundle.accessToken,
          ANTHROPIC_BASE_URL: `${options.baseUrl}/harness/claude`
        }
      }
    },
    logout: async (id: string, shared = false): Promise<HarnessAccount | undefined> => {
      const account = await resolve(id)
      if (!account) return undefined
      if (shared) {
        if (account.credential) await vault.revoke(account.credential)
        await store.remove(account.id)
      } else await setLocal(`disabled:${account.id}`, true)
      gateway.forget(account.id)
      return probe(account.id)
    },
    rename: async (id: string, label: string) => {
      const account = await resolve(id)
      if (!account) throw new Error("Account not found")
      await store.save({ ...account, label: label.trim() || account.label })
      await saveLocal({ ...account, label: label.trim() || account.label })
      return probe(account.id)
    },
    inherit: async (harnessId: string) => {
      await store.inherit(harnessId)
      for (const account of await store.accounts())
        if (account.harnessId === harnessId) await setLocal(`disabled:${account.id}`, false)
      await applySelection(harnessId)
    }
  }
}

export type SharedAccounts = ReturnType<typeof makeSharedAccounts>
