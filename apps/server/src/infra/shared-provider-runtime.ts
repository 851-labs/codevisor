import { randomBytes } from "node:crypto"
import { mkdir, readFile, symlink, writeFile, chmod } from "node:fs/promises"
import type { IncomingMessage, ServerResponse } from "node:http"
import { dirname, join, isAbsolute, resolve } from "node:path"
import { pathToFileURL } from "node:url"

import type { HarnessAccountContext } from "@codevisor/agent-runtime"
import {
  atomicWriteJson,
  MANAGED_REFRESH_PREFIX,
  openCodeAuthPlugin,
  piAuthExtension,
  providerCredential,
  providerTokenEndpoint,
  providerOAuthSupported,
  SharedCredentialError,
  type SharedCredentialVault,
  type ProviderOAuthHarness
} from "@codevisor/harness-manager"

import { providerDigest, providerSlot, type SharedProviderStore } from "./shared-provider-store.js"

export const readProviderDocument = async (path: string): Promise<Record<string, unknown>> => {
  try {
    const value: unknown = JSON.parse(await readFile(path, "utf8"))
    if (value === null || typeof value !== "object" || Array.isArray(value))
      throw new Error("Invalid credential file")
    return value as Record<string, unknown>
  } catch (cause) {
    if ((cause as NodeJS.ErrnoException).code === "ENOENT") return {}
    throw new Error("Saved provider credentials could not be read")
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

export const makeSharedProviderRuntime = (options: {
  store: SharedProviderStore
  vault: SharedCredentialVault
  dataDir: string
  baseUrl: string
}) => {
  const { store, vault, dataDir } = options
  const url = `${options.baseUrl}/harness/provider-token`
  const preparing = new Map<string, Promise<HarnessAccountContext>>()
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
    let grokApiKey: string | undefined
    for (const row of rows) {
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
    const manifestPath = join(root, "manifest.json")
    await atomicWriteJson(manifestPath, manifest)
    const runtimeEnv: Record<string, string> = {
      ...base.env,
      CODEVISOR_PROVIDER_AUTH: manifestPath
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
      const plugin = join(root, "codevisor-auth.mjs")
      await script(plugin, openCodeAuthPlugin)
      const config = env.OPENCODE_CONFIG_CONTENT
        ? (JSON.parse(env.OPENCODE_CONFIG_CONTENT) as Record<string, unknown>)
        : {}
      runtimeEnv.OPENCODE_CONFIG_CONTENT = JSON.stringify({
        ...config,
        plugin: [...(Array.isArray(config.plugin) ? config.plugin : []), pathToFileURL(plugin).href]
      })
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
      // snapshots so they cannot bypass the refresh coordinator.
      runtimeEnv.OPENCODE_AUTH_CONTENT = ""
      await atomicWriteJson(join(root, "data", "opencode", "auth.json"), auth)
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
      const quote = (value: string) => `'${value.replaceAll("'", "'\\''")}'`
      const command = join(root, "token.sh")
      await script(
        command,
        `#!/bin/sh\nif [ "\${GROK_AUTH_EXPIRED:-0}" = "1" ]; then\n  exec curl --config ${quote(curlConfig)} --data '{"force":true}'\nfi\nexec curl --config ${quote(curlConfig)} --data '{}'\n`
      )
      runtimeEnv.GROK_AUTH_PROVIDER_COMMAND = `/bin/sh ${quote(command)}`
      runtimeEnv.GROK_AUTH_PROVIDER_LABEL = "Codevisor"
    }
    return { ...base, env: runtimeEnv, ...(unsetEnv === undefined ? {} : { unsetEnv }) }
  }
  return {
    materialize: (...args: Parameters<typeof materialize>) => {
      const key = JSON.stringify(args.slice(0, 2))
      const previous = preparing.get(key) ?? Promise.resolve()
      const pending = previous
        .catch(() => undefined)
        .then(() => materialize(...args))
        .finally(() => {
          if (preparing.get(key) === pending) preparing.delete(key)
        })
      preparing.set(key, pending)
      return pending
    },
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
