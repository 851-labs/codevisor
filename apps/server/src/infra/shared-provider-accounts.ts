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
  type SharedCredentialVault
} from "@codevisor/harness-manager"
import { latestSyncTimestamp, nextSyncTimestamp } from "@codevisor/sync"
import { Effect, Schema } from "effect"

import { isRecord } from "../unknown-values.js"
import type { SharedAccountStore } from "./shared-account-store.js"
import type { OpenCode2Deps } from "./shared-provider-opencode2.js"
import { makeSharedProviderRuntime, readProviderDocument } from "./shared-provider-runtime.js"
import {
  isProviderHarness,
  makeSharedProviderStore,
  providerDigest,
  providerSlot
} from "./shared-provider-store.js"

const ProviderSource = Schema.Struct({
  fingerprint: Schema.String,
  subject: Schema.String,
  organizationId: Schema.optionalKey(Schema.String),
  credential: Schema.optionalKey(Schema.Struct({ id: Schema.String, key: Schema.String }))
})
const isProviderSource = Schema.is(ProviderSource)

export const makeSharedProviderAccounts = (options: {
  db: CodevisorDatabaseService
  store: SharedAccountStore
  vault: SharedCredentialVault
  serverId: string
  dataDir: string
  baseUrl: string
  environment: () => Promise<NodeJS.ProcessEnv>
  openCode2?: OpenCode2Deps
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
      const stored = await store.local(sourceKey)
      const previous = isProviderSource(stored) ? stored : undefined
      if (previous?.fingerprint === fingerprint) continue
      const sameSource =
        previous &&
        previous.organizationId === bundle.organizationId &&
        (previous.subject === bundle.subject ||
          (previous.subject.startsWith("grant:") && bundle.subject.startsWith("grant:")))
      if (!sameSource || !previous.credential) {
        await store.save({ ...bundle, harnessId: harness }, profile, false, false)
        const record = await store.get(slot)
        await store.setLocal(sourceKey, {
          fingerprint,
          subject: bundle.subject,
          ...(bundle.organizationId ? { organizationId: bundle.organizationId } : {}),
          ...(record?.subject === bundle.subject ? { credential: record.credential } : {})
        })
        continue
      }
      let active = false
      for (const record of [await store.get(slot), await store.get(slot, true)]) {
        if (record?.credential.id === previous.credential.id) {
          active = true
          break
        }
      }
      if (active && bundle.ownership === "external")
        await options.vault.publishExternal(previous.credential, {
          ...bundle,
          subject: previous.subject
        })
      await store.setLocal(sourceKey, { ...previous, fingerprint })
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
        } catch {}
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
      let selectionScope: HarnessAccount["selectionScope"] = "machine"
      if (
        shared ||
        (row?.credential.id === global?.credential.id && (await store.local(slot)) !== false)
      ) {
        selectionScope = "shared"
      }
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
        !(
          global?.subject === bundle.subject &&
          global.organizationId === bundle.organizationId &&
          harness !== "grok-build"
        )
      )
        return true
      const namespace = "harness-credentials"
      const entries = await Effect.runPromise(db.getSyncEntries(namespace))
      let key: string
      if (harness === "pi") {
        key = "pi-auth"
      } else if (profile === "default") {
        key = "opencode-auth"
      } else {
        key = `opencode-profile:${profile}`
      }
      const saved = entries.find((entry) => entry.key === key && !entry.deleted)
      if (typeof saved?.value !== "string") return true
      const document: unknown = JSON.parse(saved.value)
      if (!isRecord(document) || document[provider] === undefined) return true
      const { [provider]: _removed, ...remaining } = document
      await Effect.runPromise(
        db.mergeSyncEntries(namespace, [
          {
            key,
            value: JSON.stringify(remaining),
            timestamp: nextSyncTimestamp(options.serverId, latestSyncTimestamp(entries), Date.now())
          }
        ])
      )
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
      const configured = new Set(
        (await store.records(harness, profile)).map((row) => row.providerId)
      )
      return (await store.knownProviders(harness, profile)).filter(
        (providerId) => !configured.has(providerId)
      )
    },
    remove: async (harness: ProviderOAuthHarness, id: string, provider: string, shared = false) =>
      store.remove(harness, await profileId(harness, id), provider, shared),
    context: async (
      account: HarnessAccount,
      base: HarnessAccountContext
    ): Promise<HarnessAccountContext> => {
      const harness = account.harnessId
      if (!isProviderHarness(harness)) return base
      await reconcile()
      const profile = await profileId(harness, account.id)
      const env = await environment()
      return runtime.materialize(harness, profile, nativePath(harness, env, profile), base, {
        ...env,
        ...base.env
      })
    }
  }
}
