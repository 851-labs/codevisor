import { homedir } from "node:os"
import { join } from "node:path"

import type { HarnessAccountContext } from "@codevisor/agent-runtime"
import type { HarnessAccount } from "@codevisor/api"
import type { CodevisorDatabaseService } from "@codevisor/db"
import {
  parseProviderOAuth,
  SharedCredentialError,
  piAuthPath,
  openCodeAuthPath,
  type ProviderOAuthHarness,
  type SharedCredentialVault,
  type SharedCredentialReference
} from "@codevisor/harness-manager"
import { latestSyncTimestamp, nextSyncTimestamp } from "@codevisor/sync"
import { Effect } from "effect"

import type { SharedAccountStore } from "./shared-account-store.js"
import { makeSharedProviderRuntime, readProviderDocument } from "./shared-provider-runtime.js"
import { makeSharedProviderStore, providerDigest, providerSlot } from "./shared-provider-store.js"

export const makeSharedProviderAccounts = (options: {
  db: CodevisorDatabaseService
  store: SharedAccountStore
  vault: SharedCredentialVault
  serverId: string
  dataDir: string
  baseUrl: string
  environment: () => Promise<NodeJS.ProcessEnv>
}) => {
  const { db, dataDir, environment } = options
  const store = makeSharedProviderStore(options)
  const runtime = makeSharedProviderRuntime({ ...options, store })
  const profileId = async (harness: ProviderOAuthHarness, id: string) => {
    if (harness !== "opencode" || id === "default") return "default"
    const account = await Effect.runPromise(db.getHarnessAccount(id))
    if (!account || account.harnessId !== harness) throw new Error("OpenCode profile not found")
    return account.profileKind === "default" ? "default" : account.id
  }
  const nativePath = (
    harness: ProviderOAuthHarness,
    env: NodeJS.ProcessEnv,
    profile = "default"
  ) => {
    const home = env.HOME ?? homedir()
    if (harness === "pi") return piAuthPath(env)
    if (harness === "grok-build") return join(env.GROK_HOME ?? join(home, ".grok"), "auth.json")
    return openCodeAuthPath(
      profile === "default"
        ? env
        : {
            ...env,
            XDG_DATA_HOME: join(dataDir, "harness-profiles", "opencode", profile, "data")
          }
    )
  }
  const discover = async (harness: ProviderOAuthHarness, profile: string) => {
    const document = await readProviderDocument(nativePath(harness, await environment(), profile))
    for (const [id, credential] of Object.entries(document)) {
      const provider = harness === "grok-build" ? "xai" : id
      const bundle = parseProviderOAuth(harness, provider, credential, "external")
      if (!bundle) continue
      const slot = providerSlot(harness, profile, provider)
      const sourceKey = `source:${slot}`
      const fingerprint = providerDigest(JSON.stringify(credential))
      const previous = (await store.local(sourceKey)) as
        | {
            fingerprint: string
            subject: string
            organizationId?: string
            credential?: SharedCredentialReference
          }
        | undefined
      if (previous?.fingerprint === fingerprint) continue
      // Discovery never takes refresh ownership from an independently running
      // terminal. The originating CLI's refreshed access token is published.
      const sameSource =
        previous &&
        previous.organizationId === bundle.organizationId &&
        (previous.subject === bundle.subject ||
          (previous.subject.startsWith("grant:") && bundle.subject.startsWith("grant:")))
      if (sameSource && previous.credential) {
        const active = [await store.get(slot), await store.get(slot, true)].some(
          (record) => record?.credential.id === previous.credential!.id
        )
        if (active && bundle.ownership === "external")
          await options.vault.publishExternal(previous.credential, {
            ...bundle,
            subject: previous.subject
          })
        // An old terminal's background rotation must not undo a selection made
        // in Codevisor. Opaque external credentials follow the original source
        // slot; their changing refresh-token hash is not a new account.
        await store.setLocal(sourceKey, { ...previous, fingerprint })
      } else {
        await store.save({ ...bundle, harnessId: harness }, profile, false, false)
        const record = await store.get(slot)
        await store.setLocal(sourceKey, {
          fingerprint,
          subject: bundle.subject,
          ...(bundle.organizationId ? { organizationId: bundle.organizationId } : {}),
          ...(record?.subject === bundle.subject ? { credential: record.credential } : {})
        })
      }
    }
  }
  let reconciling: Promise<void> | undefined
  const reconcile = (): Promise<void> => {
    reconciling ??= (async () => {
      const profiles = (await Effect.runPromise(db.listHarnessAccounts("opencode"))).filter(
        (account) => account.profileKind === "managed"
      )
      const sources: [ProviderOAuthHarness, string][] = [
        ["pi", "default"],
        ["opencode", "default"],
        ["grok-build", "default"],
        ...profiles.map((account) => ["opencode", account.id] as [ProviderOAuthHarness, string])
      ]
      for (const [harness, profile] of sources) {
        try {
          await discover(harness, profile)
        } catch {
          /* A damaged or unavailable local source must not block the other providers. */
        }
      }
    })().finally(() => {
      reconciling = undefined
    })
    return reconciling
  }
  return {
    store,
    runtime,
    reconcile,
    account: async (account: HarnessAccount, shared = false): Promise<HarnessAccount> => {
      await reconcile()
      const slot = providerSlot("grok-build", "default", "xai")
      const row = await store.get(slot, shared)
      const global = await store.get(slot, true)
      const { email: _email, detail: _detail, authMethod: _method, ...base } = account
      const selectionScope =
        shared ||
        (row?.credential.id === global?.credential.id && (await store.local(slot)) !== false)
          ? ("shared" as const)
          : ("machine" as const)
      const unsigned: HarnessAccount = {
        ...base,
        label: "Grok",
        authState: "unauthenticated",
        isActive: true,
        canLogin: true,
        canLogout: false,
        selectionScope
      }
      if (!row) return unsigned
      try {
        const token = await options.vault.token(row.credential)
        return {
          ...unsigned,
          authState: "authenticated",
          authMethod: token.authMethod ?? "oauth",
          canLogout: true,
          label:
            token.authMethod === "apiKey"
              ? `API key ••••${token.accessToken.slice(-4)}`
              : (token.email ?? "Grok"),
          ...(token.email ? { email: token.email } : {})
        }
      } catch (cause) {
        return {
          ...unsigned,
          authState: "expired",
          canLogout: true,
          detail:
            cause instanceof SharedCredentialError
              ? cause.message
              : "Account sync is unavailable. Try again."
        }
      }
    },
    staticOverrides: async (harness: "pi" | "opencode") => {
      const providers = await store.knownProviders(harness, "default")
      const local = await Promise.all(
        providers.map(async (id) =>
          (await store.local(providerSlot(harness, "default", id))) === false ? id : undefined
        )
      )
      return local.filter((id): id is string => id !== undefined)
    },
    capture: async (
      harness: ProviderOAuthHarness,
      id: string,
      provider: string,
      credential: unknown,
      shared = false
    ) => {
      const bundle = parseProviderOAuth(harness, provider, credential, "managed")
      if (!bundle) return false
      await reconcile()
      const profile = await profileId(harness, id)
      await store.save({ ...bundle, harnessId: harness }, profile, true, shared)
      const global = await store.get(providerSlot(harness, profile, provider), true)
      if (
        global?.subject === bundle.subject &&
        global.organizationId === bundle.organizationId &&
        harness !== "grok-build"
      ) {
        const namespace = "harness-credentials"
        const entries = await Effect.runPromise(db.getSyncEntries(namespace))
        const key =
          harness === "pi"
            ? "pi-auth"
            : profile === "default"
              ? "opencode-auth"
              : `opencode-profile:${profile}`
        const saved = entries.find((entry) => entry.key === key && !entry.deleted)
        if (typeof saved?.value === "string") {
          const document = JSON.parse(saved.value) as Record<string, unknown>
          if (document[provider] !== undefined) {
            delete document[provider]
            await Effect.runPromise(
              db.mergeSyncEntries(namespace, [
                {
                  key,
                  value: JSON.stringify(document),
                  timestamp: nextSyncTimestamp(
                    options.serverId,
                    latestSyncTimestamp(entries),
                    Date.now()
                  )
                }
              ])
            )
          }
        }
      }
      return true
    },
    configured: async (harness: ProviderOAuthHarness, id: string, shared = false) => {
      await reconcile()
      return (await store.records(harness, await profileId(harness, id), shared)).map(
        (row) => row.providerId
      )
    },
    disabled: async (harness: ProviderOAuthHarness, id: string) => {
      const profile = await profileId(harness, id)
      const configured = (await store.records(harness, profile)).map((row) => row.providerId)
      return (await store.knownProviders(harness, profile)).filter((id) => !configured.includes(id))
    },
    remove: async (harness: ProviderOAuthHarness, id: string, provider: string, shared = false) =>
      store.remove(harness, await profileId(harness, id), provider, shared),
    context: async (
      account: HarnessAccount,
      base: HarnessAccountContext
    ): Promise<HarnessAccountContext> => {
      if (!["pi", "opencode", "grok-build"].includes(account.harnessId)) return base
      await reconcile()
      const harness = account.harnessId as ProviderOAuthHarness
      const profile = await profileId(harness, account.id)
      const env = await environment()
      return runtime.materialize(harness, profile, nativePath(harness, env, profile), base, {
        ...env,
        ...base.env
      })
    }
  }
}
