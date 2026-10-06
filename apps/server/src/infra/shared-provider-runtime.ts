import { randomBytes } from "node:crypto"
import { mkdir, readFile, symlink, writeFile, chmod } from "node:fs/promises"
import type { IncomingMessage, ServerResponse } from "node:http"
import { dirname, join, isAbsolute, resolve } from "node:path"

import type { HarnessAccountContext } from "@codevisor/agent-runtime"
import {
  atomicWriteJson,
  MANAGED_REFRESH_PREFIX,
  piAuthExtension,
  providerCredential,
  providerTokenEndpoint,
  providerOAuthSupported,
  SharedCredentialError,
  type SharedCredentialVault,
  type ProviderOAuthHarness
} from "@codevisor/harness-manager"

import {
  makeOpenCode2Deps,
  makeOpenCode2Materializer,
  type OpenCode2Deps
} from "./shared-provider-opencode2.js"
import { providerDigest, providerSlot, type SharedProviderStore } from "./shared-provider-store.js"

export const readProviderDocument = async (path: string): Promise<Record<string, unknown>> => {
  try {
    const value: unknown = JSON.parse(await readFile(path, "utf8"))
    if (value === null || typeof value !== "object" || Array.isArray(value))
      throw new Error("Invalid credential file")
    return value as Record<string, unknown>
  } catch (cause) {
    if ((cause as NodeJS.ErrnoException).code === "ENOENT") return {}
    throw new Error("Saved provider credentials could not be read", { cause })
  }
}

interface Capability {
  capability: string
  slot: string
  credentialId: string
}
interface ManifestProvider {
  capability: string
  endpoint?: string
  access: string
}
const shellQuote = (value: string) => `'${value.replaceAll("'", "'\\''")}'`
const script = async (path: string, content: string) => {
  await mkdir(dirname(path), { recursive: true, mode: 0o700 })
  await writeFile(path, content, { mode: 0o600 })
  await chmod(path, 0o600)
}
const linkResource = async (source: string, destination: string) => {
  try {
    await symlink(source, destination)
  } catch (cause) {
    if ((cause as NodeJS.ErrnoException).code !== "EEXIST") throw cause
  }
}

/// OpenCode re-reads auth.json on every request, and its built-in OAuth
/// plugins (openai/codex.ts, xai.ts) refresh only once a token is nearly
/// expired. Keeping the file ahead of that means OpenCode never refreshes on
/// its own: the rotating grant stays in the vault, and the file holds an inert
/// placeholder where a refresh token would be. The importer already ignores
/// anything under the managed prefix.
const OPENCODE_MANAGED_REFRESH = `${MANAGED_REFRESH_PREFIX}managed`
/// The vault serves OpenCode tokens with over six minutes left. Rewriting once
/// seven remain stays clear of xAI's two-minute refresh skew between ticks.
const OPENCODE_REFRESH_AHEAD_MS = 7 * 60_000
/// Wall-clock polling rather than one timer per expiry: a Mac's timers stop
/// while it sleeps, so a long timer can fire well after its token expired.
const OPENCODE_TICK_MS = 30_000
const OPENCODE_RETRY_MS = 60_000
/// A profile no turn has used for this long stops being refreshed in the
/// background; the next turn catches it up before it starts.
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
  /// One profile's files are written by one operation at a time.
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

  /// Puts the profile's current shared credentials into an OpenCode auth
  /// document, and returns when they next need rewriting. A provider the
  /// vault can't serve right now keeps whatever entry it has, which may still
  /// be valid; one no longer shared loses its managed entry.
  const withOpenCodeCredentials = async (
    profile: string,
    document: Record<string, unknown>
  ): Promise<number> => {
    const rows = await store.records("opencode", profile)
    const shared = new Set(rows.map((row) => row.providerId))
    for (const [id, value] of Object.entries(document)) {
      if (
        !shared.has(id) &&
        (value as { refresh?: unknown } | null)?.refresh === OPENCODE_MANAGED_REFRESH
      )
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
  /// The broker capability standing in for one provider row's grant: kept
  /// while the row keeps its credential, replaced (revoking the old one)
  /// when the credential changes.
  const capabilityFor = async (
    harness: ProviderOAuthHarness,
    profile: string,
    row: { readonly providerId: string; readonly credential: { readonly id: string } }
  ): Promise<Capability> => {
    const slot = providerSlot(harness, profile, row.providerId)
    const capKey = `cap:${providerDigest(slot)}`
    const previous = (await store.local(capKey)) as Capability | undefined
    const cap: Capability =
      previous?.credentialId === row.credential.id
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

  const materialize = async (
    harness: ProviderOAuthHarness,
    profile: string,
    nativePath: string,
    base: HarnessAccountContext,
    env: NodeJS.ProcessEnv
  ): Promise<HarnessAccountContext> => {
    const rows = await store.records(harness, profile)
    const known = await store.knownProviders(harness, profile)
    if (!known.length) return base
    const root = join(dataDir, "provider-auth", harness, providerDigest(profile))
    const manifest: { url: string; providers: Record<string, ManifestProvider> } = {
      url,
      providers: {}
    }
    const auth = await readProviderDocument(nativePath)
    // Uninspected plugins own their refresh behavior. Duplicating their grant
    // into a second writable file would create another independent refresher.
    if (harness !== "grok-build") {
      for (const [id, value] of Object.entries(auth)) {
        if (
          typeof value === "object" &&
          value !== null &&
          (value as { type?: unknown }).type === "oauth" &&
          !providerOAuthSupported(harness, id)
        )
          throw new Error(`${id} uses local OAuth. Use a separate profile for shared accounts.`)
      }
    }
    for (const id of known) {
      const value = auth[id]
      if (
        typeof value === "object" &&
        value !== null &&
        (value as { type?: unknown }).type === "oauth"
      )
        delete auth[id]
    }
    if (harness === "opencode" && ((await openCode2.majorVersion(env)) ?? 1) >= 2)
      return materializeOpenCode2(profile, root, base, env, rows, auth)
    let grokApiKey: string | undefined
    // OpenCode 1 never refreshes for itself (see OPENCODE_MANAGED_REFRESH),
    // so it gets no broker capability.
    for (const row of harness === "opencode" ? [] : rows) {
      const cap = await capabilityFor(harness, profile, row)
      // An expired or unavailable provider must not prevent the other
      // providers in the same profile from working. Its native credential is
      // omitted so the harness requests sign-in instead of using stale auth.
      const token = await vault.token(row.credential).catch(() => undefined)
      if (!token) continue
      if (harness === "grok-build" && token.authMethod === "apiKey") grokApiKey = token.accessToken
      auth[row.providerId] = providerCredential(token, MANAGED_REFRESH_PREFIX + cap.capability)
      const endpoint = providerTokenEndpoint(row.providerId)
      manifest.providers[row.providerId] = {
        capability: cap.capability,
        access: token.accessToken,
        ...(endpoint ? { endpoint } : {})
      }
    }
    const runtimeEnv: Record<string, string> = { ...base.env }
    if (harness !== "opencode") {
      const manifestPath = join(root, "manifest.json")
      await atomicWriteJson(manifestPath, manifest)
      runtimeEnv.CODEVISOR_PROVIDER_AUTH = manifestPath
    }
    let unsetEnv: ReadonlyArray<string> | undefined = base.unsetEnv
    if (harness === "pi") {
      const source = dirname(nativePath)
      await mkdir(join(source, "sessions"), { recursive: true, mode: 0o700 })
      // Keep transcripts and user resources in their existing locations. Only
      // authentication and our extension use the managed agent directory.
      for (const name of ["sessions", "skills", "prompts", "themes", "models.json", "AGENTS.md"]) {
        await linkResource(join(source, name), join(root, name))
      }
      const settings = await readProviderDocument(join(source, "settings.json"))
      for (const key of ["extensions", "skills", "prompts", "themes"]) {
        if (Array.isArray(settings[key]))
          settings[key] = settings[key].map((value) =>
            typeof value === "string" && !isAbsolute(value) && !value.startsWith("~")
              ? resolve(source, value)
              : value
          )
      }
      const extensions = Array.isArray(settings.extensions) ? settings.extensions : []
      await atomicWriteJson(join(root, "settings.json"), {
        ...settings,
        extensions: [...extensions, join(source, "extensions")]
      })
      await atomicWriteJson(join(root, "auth.json"), auth)
      await script(join(root, "extensions", "codevisor-auth.ts"), piAuthExtension)
      runtimeEnv.PI_CODING_AGENT_DIR = root
    } else if (harness === "opencode") {
      // A default profile also gets isolated credential storage: no managed
      // placeholder or refreshed token is written into a terminal's auth file.
      runtimeEnv.XDG_DATA_HOME = join(root, "data")
      // Keep existing conversations and repository state when authentication
      // moves to an isolated directory. Relative database paths are native-data
      // relative; an explicit in-memory database must remain in memory.
      const source = dirname(nativePath)
      const database = env.OPENCODE_DB || "opencode.db"
      runtimeEnv.OPENCODE_DB = database === ":memory:" ? database : resolve(source, database)
      await mkdir(join(root, "data", "opencode"), { recursive: true, mode: 0o700 })
      for (const name of ["storage", "snapshot", "worktree", "repos", "log", "bin"]) {
        await mkdir(join(source, name), { recursive: true, mode: 0o700 })
        await linkResource(join(source, name), join(root, "data", "opencode", name))
      }
      // OPENCODE_AUTH_CONTENT is read before auth.json; override inherited
      // snapshots so they cannot bypass the credentials kept current here.
      runtimeEnv.OPENCODE_AUTH_CONTENT = ""
      const path = join(root, "data", "opencode", "auth.json")
      const dueAt = await withOpenCodeCredentials(profile, auth)
      await atomicWriteJson(path, auth)
      // One entry per profile for the server's lifetime (its path depends
      // only on the profile), so every context's hook keeps the same one.
      const entry = openCode.get(profile) ?? { path, dueAt, usedAt: 0 }
      entry.dueAt = dueAt
      openCode.set(profile, entry)
      keepOpenCodeCurrent(entry)
      return {
        ...base,
        env: runtimeEnv,
        // The background tick can't run while the machine sleeps; a turn
        // that starts right after waking catches up first.
        beforeTurn: async () => {
          keepOpenCodeCurrent(entry)
          await refreshOpenCode(profile)
        }
      }
    } else {
      runtimeEnv.GROK_HOME = root
      runtimeEnv.GROK_AUTH_PATH = join(root, "auth.json")
      // Grok treats an empty-but-present `GROK_AUTH` (or provider command) as
      // a supplied credential, ignores its external provider, and refuses
      // `session/new` with "Authentication required". Anything inherited from
      // the user's shell is removed from the process environment instead.
      const grokUnset = [
        "GROK_AUTH",
        ...(grokApiKey ? ["GROK_AUTH_PROVIDER_COMMAND"] : ["XAI_API_KEY"])
      ]
      for (const name of grokUnset) delete runtimeEnv[name]
      unsetEnv = [...new Set([...(base.unsetEnv ?? []), ...grokUnset])]
      if (grokApiKey) runtimeEnv.XAI_API_KEY = grokApiKey
      await atomicWriteJson(join(root, "auth.json"), {})
      const source = dirname(nativePath)
      await mkdir(join(source, "sessions"), { recursive: true, mode: 0o700 })
      for (const name of ["sessions", "config.toml"]) {
        await linkResource(join(source, name), join(root, name))
      }
      if (grokApiKey) return { ...base, env: runtimeEnv, unsetEnv }
      if (!manifest.providers.xai) {
        runtimeEnv.GROK_AUTH_PROVIDER_COMMAND = "false"
        return { ...base, env: runtimeEnv, unsetEnv }
      }
      const managed = manifest.providers.xai!
      // curl reads the capability from a private config, never command-line
      // arguments (Grok logs the provider command). No shell interpolation of
      // credentials or provider-controlled values is involved.
      const curlConfig = join(root, "curl.conf")
      await script(
        curlConfig,
        `url = ${JSON.stringify(url)}\nheader = ${JSON.stringify(`Authorization: Bearer ${managed.capability}`)}\nheader = "Content-Type: application/json"\nrequest = "POST"\nsilent\nshow-error\nfail\nmax-time = 6\n`
      )
      const command = join(root, "token.sh")
      await script(
        command,
        `#!/bin/sh\nif [ "\${GROK_AUTH_EXPIRED:-0}" = "1" ]; then\n  exec curl --config ${shellQuote(curlConfig)} --data '{"force":true}'\nfi\nexec curl --config ${shellQuote(curlConfig)} --data '{}'\n`
      )
      runtimeEnv.GROK_AUTH_PROVIDER_COMMAND = `/bin/sh ${shellQuote(command)}`
      runtimeEnv.GROK_AUTH_PROVIDER_LABEL = "Codevisor"
    }
    return { ...base, env: runtimeEnv, ...(unsetEnv === undefined ? {} : { unsetEnv }) }
  }
  return {
    materialize: (...args: Parameters<typeof materialize>) =>
      serialize(JSON.stringify(args.slice(0, 2)), () => materialize(...args)),
    handle: async (request: IncomingMessage, response: ServerResponse): Promise<void> => {
      response.setHeader("Cache-Control", "no-store")
      if (
        request.headers.origin !== undefined ||
        !["127.0.0.1", "::1", "::ffff:127.0.0.1"].includes(request.socket.remoteAddress ?? "")
      ) {
        response.writeHead(403).end()
        return
      }
      if (request.method !== "POST") {
        response.writeHead(405).end()
        return
      }
      const bearer = request.headers.authorization?.match(/^Bearer ([\w-]{43})$/)?.[1]
      const cap = (await store.localEntries())
        .filter((entry) => entry.key.startsWith("cap:"))
        .map((entry) => entry.value as Capability | null)
        .filter((value): value is Capability => value !== null && typeof value === "object")
        .find((value) => value.capability === bearer)
      if (!bearer || !cap) {
        response.writeHead(401).end()
        return
      }
      const row = await store.get(cap.slot)
      if (!row || row.credential.id !== cap.credentialId) {
        response.writeHead(401).end()
        return
      }
      try {
        const chunks: Buffer[] = []
        let size = 0
        for await (const chunk of request) {
          size += Buffer.byteLength(chunk)
          if (size > 16_384) {
            response.writeHead(413).end()
            return
          }
          chunks.push(Buffer.from(chunk))
        }
        let body: { rejectedAccessToken?: unknown; force?: unknown }
        try {
          body = JSON.parse(Buffer.concat(chunks).toString()) as typeof body
        } catch {
          response.writeHead(400).end()
          return
        }
        if (
          !body ||
          typeof body !== "object" ||
          Array.isArray(body) ||
          (body.rejectedAccessToken !== undefined && typeof body.rejectedAccessToken !== "string")
        ) {
          response.writeHead(400).end()
          return
        }
        let token = await vault.token(
          row.credential,
          body.rejectedAccessToken as string | undefined
        )
        if (body.force === true && row.harnessId === "grok-build")
          token = await vault.token(row.credential, token.accessToken)
        response.writeHead(200, { "Content-Type": "application/json" }).end(
          JSON.stringify({
            credential: providerCredential(token, MANAGED_REFRESH_PREFIX + cap.capability),
            ...(token.idToken ? { idToken: token.idToken } : {}),
            // Grok's external-provider contract ignores other fields. Issuer
            // preserves first-party subscription behavior; no refresh_token.
            access_token: token.accessToken,
            expires_in: Math.max(1, Math.floor((token.expiresAt - Date.now()) / 1000)),
            issuer: "https://auth.x.ai"
          })
        )
      } catch (cause) {
        response
          .writeHead(
            cause instanceof SharedCredentialError && cause.reason === "revoked" ? 401 : 503,
            { "Content-Type": "application/json" }
          )
          .end(JSON.stringify({ error: "Reconnect this account in Codevisor." }))
      }
    }
  }
}
