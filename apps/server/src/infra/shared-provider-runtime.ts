import { randomBytes } from "node:crypto"
import { mkdir, symlink, writeFile, chmod } from "node:fs/promises"
import { dirname, join, resolve } from "node:path"

import type { HarnessAccountContext } from "@codevisor/agent-runtime"
import {
  atomicWriteJson,
  MANAGED_REFRESH_PREFIX,
  piAuthExtension,
  providerCredential,
  providerTokenEndpoint,
  type SharedCredentialVault,
  type SharedTokenBundle,
  type ProviderOAuthHarness
} from "@codevisor/harness-manager"

import { errorCode, field } from "../unknown-values.js"
import {
  prepareProviderAuthDocument,
  readProviderDocument,
  resolvePiResourcePaths
} from "./shared-provider-documents.js"
import {
  grokCredentialPlan,
  grokCurlConfig,
  grokEnv,
  grokResources,
  grokTokenCommand,
  grokTokenScript
} from "./shared-provider-grok.js"
import {
  makeOpenCode2Deps,
  makeOpenCode2Materializer,
  type OpenCode2Deps
} from "./shared-provider-opencode2.js"
import {
  providerDigest,
  providerSlot,
  type SharedProviderRecord,
  type SharedProviderStore
} from "./shared-provider-store.js"
import {
  isCapability,
  makeProviderTokenBroker,
  type Capability
} from "./shared-provider-token-broker.js"

export { readProviderDocument } from "./shared-provider-documents.js"

interface ManifestProvider {
  capability: string
  endpoint?: string
  access: string
}
type ProviderManifest = {
  url: string
  providers: Record<string, ManifestProvider>
}
interface ResourceLink {
  readonly source: string
  readonly destination: string
}
const script = async (path: string, content: string) => {
  await mkdir(dirname(path), privateDirectory)
  await writeFile(path, content, { mode: 0o600 })
  await chmod(path, 0o600)
}
const linkResource = async (link: ResourceLink) => {
  try {
    await symlink(link.source, link.destination)
  } catch (cause) {
    if (errorCode(cause) !== "EEXIST") throw cause
  }
}

const OPENCODE_MANAGED_REFRESH = `${MANAGED_REFRESH_PREFIX}managed`
const OPENCODE_REFRESH_AHEAD_MS = 7 * 60_000
const OPENCODE_TICK_MS = 30_000
const OPENCODE_RETRY_MS = 60_000
const OPENCODE_IDLE_MS = 24 * 60 * 60_000

interface OpenCodeProfile {
  readonly path: string
  dueAt: number
  usedAt: number
}

export const makeSharedProviderRuntime = (options: {
  store: SharedProviderStore
  vault: SharedCredentialVault
  dataDir: string
  baseUrl: string
  openCode2?: OpenCode2Deps
}) => {
  const { store, vault, dataDir } = options
  const openCode2 = options.openCode2 ?? makeOpenCode2Deps()
  const url = `${options.baseUrl}/harness/provider-token`
  const preparing = new Map<string, Promise<unknown>>()
  const serialize = <A>(key: string, operation: () => Promise<A>): Promise<A> => {
    const previous = preparing.get(key) ?? Promise.resolve()
    const pending = previous
      .catch(() => undefined)
      .then(operation)
      .finally(() => {
        if (preparing.get(key) === pending) preparing.delete(key)
      })
    preparing.set(key, pending)
    return pending
  }

  const withOpenCodeCredentials = async (
    profile: string,
    document: Record<string, unknown>
  ): Promise<number> => {
    const rows = await store.records("opencode", profile)
    const shared = new Set(rows.map((row) => row.providerId))
    for (const [id, value] of Object.entries(document)) {
      if (!shared.has(id) && field(value, "refresh") === OPENCODE_MANAGED_REFRESH)
        delete document[id]
    }
    let dueAt = Number.POSITIVE_INFINITY
    for (const row of rows) {
      const token = await vault.token(row.credential).catch(() => undefined)
      if (!token) {
        dueAt = Math.min(dueAt, Date.now() + OPENCODE_RETRY_MS)
        continue
      }
      document[row.providerId] = providerCredential(token, OPENCODE_MANAGED_REFRESH)
      dueAt = Math.min(dueAt, token.expiresAt - OPENCODE_REFRESH_AHEAD_MS)
    }
    return dueAt
  }

  const openCode = new Map<string, OpenCodeProfile>()
  let ticker: ReturnType<typeof setInterval> | undefined
  const refreshOpenCode = (profile: string): Promise<void> =>
    serialize(JSON.stringify(["opencode", profile]), async () => {
      const entry = openCode.get(profile)
      if (entry === undefined || Date.now() < entry.dueAt) return
      try {
        const document = await readProviderDocument(entry.path)
        entry.dueAt = await withOpenCodeCredentials(profile, document)
        await atomicWriteJson(entry.path, document)
      } catch {
        entry.dueAt = Date.now() + OPENCODE_RETRY_MS
      }
    })
  const tick = () => {
    let active = false
    for (const [profile, entry] of openCode) {
      if (Date.now() - entry.usedAt > OPENCODE_IDLE_MS) continue
      active = true
      if (Date.now() >= entry.dueAt) void refreshOpenCode(profile)
    }
    if (!active && ticker !== undefined) {
      clearInterval(ticker)
      ticker = undefined
    }
  }
  const keepOpenCodeCurrent = (entry: OpenCodeProfile) => {
    entry.usedAt = Date.now()
    if (ticker === undefined) {
      ticker = setInterval(tick, OPENCODE_TICK_MS)
      ticker.unref()
    }
  }
  const capabilityFor = async (
    harness: ProviderOAuthHarness,
    profile: string,
    row: { readonly providerId: string; readonly credential: { readonly id: string } }
  ): Promise<Capability> => {
    const slot = providerSlot(harness, profile, row.providerId)
    const capKey = `cap:${providerDigest(slot)}`
    const previous = await store.local(capKey)
    const cap: Capability =
      isCapability(previous) && previous.credentialId === row.credential.id
        ? previous
        : {
            capability: randomBytes(32).toString("base64url"),
            slot,
            credentialId: row.credential.id
          }
    await store.setLocal(capKey, cap)
    return cap
  }

  const materializeOpenCode2 = makeOpenCode2Materializer({
    vault,
    url,
    capabilityFor: (profile, row) => capabilityFor("opencode", profile, row),
    writePrivate: script,
    openCode2
  })

  const trackOpenCode = (profile: string, path: string, dueAt: number): OpenCodeProfile => {
    const entry = openCode.get(profile) ?? { path, dueAt, usedAt: 0 }
    entry.dueAt = dueAt
    openCode.set(profile, entry)
    return entry
  }

  const materializePi = async (
    profile: string,
    nativePath: string,
    base: HarnessAccountContext
  ): Promise<HarnessAccountContext> => {
    const rows = await store.records("pi", profile)
    const known = await store.knownProviders("pi", profile)
    if (!known.length) return base

    const root = providerAuthRoot(dataDir, "pi", profile)
    const auth = await readProviderDocument(nativePath)
    prepareProviderAuthDocument("pi", auth, known)
    const manifest: ProviderManifest = { url, providers: {} }
    for (const row of rows) {
      const cap = await capabilityFor("pi", profile, row)
      const token = await vault.token(row.credential).catch(() => undefined)
      if (token) shareGrant(auth, manifest, row, cap, token)
    }

    const manifestPath = join(root, "manifest.json")
    const runtimeEnv = {
      ...base.env,
      CODEVISOR_PROVIDER_AUTH: manifestPath,
      PI_CODING_AGENT_DIR: root
    }
    await atomicWriteJson(manifestPath, manifest)
    const unsetEnv = base.unsetEnv

    const source = dirname(nativePath)
    await mkdir(join(source, "sessions"), privateDirectory)
    for (const link of resourceLinks(source, root, piResources)) await linkResource(link)
    const settings = await readProviderDocument(join(source, "settings.json"))
    await atomicWriteJson(join(root, "settings.json"), piRuntimeSettings(settings, source))
    await atomicWriteJson(join(root, "auth.json"), auth)
    await script(join(root, "extensions", "codevisor-auth.ts"), piAuthExtension)
    return { ...base, env: runtimeEnv, ...(unsetEnv === undefined ? {} : { unsetEnv }) }
  }

  const materializeOpenCode = async (
    profile: string,
    nativePath: string,
    base: HarnessAccountContext,
    env: NodeJS.ProcessEnv
  ): Promise<HarnessAccountContext> => {
    const rows = await store.records("opencode", profile)
    const known = await store.knownProviders("opencode", profile)
    if (!known.length) return base

    const root = providerAuthRoot(dataDir, "opencode", profile)
    const auth = await readProviderDocument(nativePath)
    prepareProviderAuthDocument("opencode", auth, known)
    if (((await openCode2.majorVersion(env)) ?? 1) >= 2)
      return materializeOpenCode2(profile, root, base, env, rows, auth)

    const source = dirname(nativePath)
    const runtimeEnv = openCodeEnv(base, root, source, env)
    const data = join(root, "data", "opencode")
    await mkdir(data, privateDirectory)
    for (const link of resourceLinks(source, data, openCodeResources)) {
      await mkdir(link.source, privateDirectory)
      await linkResource(link)
    }

    const path = join(data, "auth.json")
    const dueAt = await withOpenCodeCredentials(profile, auth)
    await atomicWriteJson(path, auth)
    const entry = trackOpenCode(profile, path, dueAt)
    keepOpenCodeCurrent(entry)
    return {
      ...base,
      env: runtimeEnv,
      beforeTurn: async () => {
        keepOpenCodeCurrent(entry)
        await refreshOpenCode(profile)
      }
    }
  }

  const materializeGrok = async (
    profile: string,
    nativePath: string,
    base: HarnessAccountContext
  ): Promise<HarnessAccountContext> => {
    const rows = await store.records("grok-build", profile)
    const known = await store.knownProviders("grok-build", profile)
    if (!known.length) return base

    const root = providerAuthRoot(dataDir, "grok-build", profile)
    const auth = await readProviderDocument(nativePath)
    prepareProviderAuthDocument("grok-build", auth, known)
    const manifest: ProviderManifest = { url, providers: {} }
    let apiKey: string | undefined
    for (const row of rows) {
      const cap = await capabilityFor("grok-build", profile, row)
      const token = await vault.token(row.credential).catch(() => undefined)
      if (!token) continue
      if (token.authMethod === "apiKey") apiKey = token.accessToken
      shareGrant(auth, manifest, row, cap, token)
    }

    const plan = grokCredentialPlan(root, apiKey, manifest.providers.xai)
    const manifestPath = join(root, "manifest.json")
    const runtimeEnv = grokEnv(base, root, manifestPath, plan)
    await atomicWriteJson(manifestPath, manifest)
    const unsetEnv = [...new Set([...(base.unsetEnv ?? []), ...plan.unset])]
    await atomicWriteJson(join(root, "auth.json"), {})

    const source = dirname(nativePath)
    await mkdir(join(source, "sessions"), privateDirectory)
    for (const link of resourceLinks(source, root, grokResources)) await linkResource(link)
    if (plan.broker) {
      const curlConfig = join(root, "curl.conf")
      await script(curlConfig, grokCurlConfig(url, plan.broker.capability))
      await script(grokTokenCommand(root), grokTokenScript(curlConfig))
    }
    return { ...base, env: runtimeEnv, unsetEnv }
  }

  const materialize = (
    harness: ProviderOAuthHarness,
    profile: string,
    nativePath: string,
    base: HarnessAccountContext,
    env: NodeJS.ProcessEnv
  ): Promise<HarnessAccountContext> => {
    if (harness === "pi") return materializePi(profile, nativePath, base)
    if (harness === "opencode") return materializeOpenCode(profile, nativePath, base, env)
    return materializeGrok(profile, nativePath, base)
  }
  return {
    materialize: (...args: Parameters<typeof materialize>) =>
      serialize(JSON.stringify(args.slice(0, 2)), () => materialize(...args)),
    handle: makeProviderTokenBroker(store, vault)
  }
}

const privateDirectory = { recursive: true, mode: 0o700 }
const piResources = ["sessions", "skills", "prompts", "themes", "models.json", "AGENTS.md"]
const openCodeResources = ["storage", "snapshot", "worktree", "repos", "log", "bin"]

const providerAuthRoot = (dataDir: string, harness: ProviderOAuthHarness, profile: string) =>
  join(dataDir, "provider-auth", harness, providerDigest(profile))

const resourceLinks = (
  source: string,
  destination: string,
  names: ReadonlyArray<string>
): ReadonlyArray<ResourceLink> =>
  names.map((name) => ({ source: join(source, name), destination: join(destination, name) }))

const shareGrant = (
  auth: Record<string, unknown>,
  manifest: ProviderManifest,
  row: SharedProviderRecord,
  cap: Capability,
  token: SharedTokenBundle
): void => {
  auth[row.providerId] = providerCredential(token, MANAGED_REFRESH_PREFIX + cap.capability)
  const endpoint = providerTokenEndpoint(row.providerId)
  manifest.providers[row.providerId] = {
    capability: cap.capability,
    access: token.accessToken,
    ...(endpoint ? { endpoint } : {})
  }
}

const piRuntimeSettings = (settings: Record<string, unknown>, source: string) => {
  resolvePiResourcePaths(settings, source)
  const extensions = Array.isArray(settings.extensions) ? settings.extensions : []
  return { ...settings, extensions: [...extensions, join(source, "extensions")] }
}

const openCodeEnv = (
  base: HarnessAccountContext,
  root: string,
  source: string,
  env: NodeJS.ProcessEnv
): Record<string, string> => ({
  ...base.env,
  XDG_DATA_HOME: join(root, "data"),
  OPENCODE_DB: openCodeDatabase(source, env),
  OPENCODE_AUTH_CONTENT: ""
})

const openCodeDatabase = (source: string, env: NodeJS.ProcessEnv): string => {
  const database = env.OPENCODE_DB || "opencode.db"
  return database === ":memory:" ? database : resolve(source, database)
}
