import { chmod, mkdir, readFile, rename, rm, writeFile } from "node:fs/promises"
import { homedir } from "node:os"
import { dirname, join } from "node:path"
import lockfile from "proper-lockfile"
import { openCodeAuthPath } from "./opencode-auth.js"

/// Phase 20: the static credential ferry's file layer. Each source knows
/// ONE credential surface — where it lives, which parts are honestly
/// static (API keys, never rotating OAuth token families), and how to
/// graft ferried content into the local file without disturbing what must
/// stay machine-local. The LWW reconcile above this
/// (apps/server/src/infra/credential-sync.ts) never touches files itself.
///
/// Static-only rules, per surface:
/// - pi:        entries with type "api_key"; OAuth entries never travel and
///              are preserved verbatim on the receiving side.
/// - opencode:  entries whose type is not "oauth" (api keys and well-known
///              env credentials); OAuth entries preserved likewise.
/// - codex:     the whole auth.json, but ONLY while it carries no rotating
///              `tokens` family (API-key logins); a machine with a live
///              ChatGPT login neither publishes nor lets ferried content
///              clobber it.
/// - devin:     credentials.toml verbatim — a static API key plus static
///              endpoint URLs, no token family at all.
///
/// Recon'd and deliberately NOT ferried (Phase 21 close-out):
/// - grok-build: ~/.grok/auth.json is an OIDC session (refresh_token +
///              expires_at) — rotating, single-owner, relayed re-auth only.
/// - github-copilot-cli: no standalone credential file (auth rides GitHub's
///              keyring/session store); nothing honestly static to ferry.
/// - gemini / qwen-code: browser OAuth session stores; rotating families,
///              relayed re-auth only.
/// - kilo:      no sign-in required; nothing to ferry.
export interface CredentialSource {
  readonly id: string
  /// Canonical static content, or undefined when there is nothing to
  /// publish from this machine (missing file, or rotating-only content).
  readonly read: () => Promise<string | undefined>
  readonly apply: (content: string) => Promise<void>
  /// Applies a deletion for sources where file absence means "signed
  /// out" (tombstoneOnAbsence) rather than "never had it".
  readonly applyDelete?: () => Promise<void>
  readonly tombstoneOnAbsence: boolean
}

export interface CredentialFerryConfig {
  readonly resolveEnv: () => Promise<NodeJS.ProcessEnv>
}

/// Stable output for change detection: identical logical content must
/// produce identical strings on every machine.
export const canonicalCredentialJson = (value: Record<string, unknown>): string =>
  JSON.stringify(
    Object.fromEntries(Object.entries(value).toSorted(([a], [b]) => a.localeCompare(b)))
  )

const readJsonFile = async (path: string): Promise<Record<string, unknown> | undefined> => {
  let raw: string
  try {
    raw = await readFile(path, "utf8")
  } catch (cause) {
    if ((cause as NodeJS.ErrnoException).code === "ENOENT") return undefined
    throw cause
  }
  const parsed: unknown = JSON.parse(raw)
  if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) {
    throw new Error(`Not a credential object: ${path}`)
  }
  return parsed as Record<string, unknown>
}

const atomicWriteJson = async (path: string, value: Record<string, unknown>): Promise<void> => {
  await mkdir(dirname(path), { recursive: true, mode: 0o700 })
  const temporary = `${path}.codevisor-${process.pid}.tmp`
  await writeFile(temporary, JSON.stringify(value, null, 2), { encoding: "utf8", mode: 0o600 })
  await rename(temporary, path)
  await chmod(path, 0o600)
}

/// Serializes our read-modify-write against the harness CLI's own file
/// access (pi cooperates with proper-lockfile; for others the lock is a
/// harmless extra). The file must exist for proper-lockfile to lock.
const withFileLock = async (path: string, body: () => Promise<void>): Promise<void> => {
  await mkdir(dirname(path), { recursive: true, mode: 0o700 })
  try {
    await writeFile(path, "{}", { encoding: "utf8", flag: "wx", mode: 0o600 })
  } catch (cause) {
    if ((cause as NodeJS.ErrnoException).code !== "EEXIST") throw cause
  }
  const release = await lockfile.lock(path, { retries: { retries: 5, minTimeout: 100 } })
  try {
    await body()
  } finally {
    await release()
  }
}

const credentialType = (value: unknown): string | undefined =>
  typeof value === "object" && value !== null && "type" in value
    ? String((value as { type: unknown }).type)
    : undefined

/// A merge-class source: publishes the subset of entries matching
/// `travels`, and applies by REPLACING that class on the target (so
/// removals propagate) while preserving everything else — OAuth entries
/// above all.
const mergeClassSource = (
  id: string,
  pathFor: () => Promise<string>,
  travels: (type: string | undefined) => boolean
): CredentialSource => ({
  id,
  tombstoneOnAbsence: false,
  read: async () => {
    const current = await readJsonFile(await pathFor())
    if (current === undefined) return undefined
    const subset = Object.fromEntries(
      Object.entries(current).filter(([, value]) => travels(credentialType(value)))
    )
    return canonicalCredentialJson(subset)
  },
  apply: async (content) => {
    const incoming = JSON.parse(content) as Record<string, unknown>
    const path = await pathFor()
    await withFileLock(path, async () => {
      /* v8 ignore next -- withFileLock creates the file before this read. */
      const current = (await readJsonFile(path)) ?? {}
      const preserved = Object.fromEntries(
        Object.entries(current).filter(([, value]) => !travels(credentialType(value)))
      )
      await atomicWriteJson(path, { ...preserved, ...incoming })
    })
  }
})

const codexHasRotatingTokens = (value: Record<string, unknown> | undefined): boolean =>
  typeof value?.tokens === "object" && value.tokens !== null

export const credentialFerrySources = (
  config: CredentialFerryConfig
): ReadonlyArray<CredentialSource> => {
  const piPath = async (): Promise<string> => {
    const env = await config.resolveEnv()
    const custom = env.PI_CODING_AGENT_DIR?.trim()
    return custom
      ? join(custom.replace(/^~(?=$|\/)/, env.HOME ?? homedir()), "auth.json")
      : join(env.HOME ?? homedir(), ".pi", "agent", "auth.json")
  }
  const openCodePath = async (): Promise<string> => openCodeAuthPath(await config.resolveEnv())
  const codexPath = async (): Promise<string> => {
    const env = await config.resolveEnv()
    const home = env.CODEX_HOME?.trim()
    return join(home ? home : join(env.HOME ?? homedir(), ".codex"), "auth.json")
  }

  const codex: CredentialSource = {
    id: "codex-auth-file",
    tombstoneOnAbsence: true,
    read: async () => {
      const current = await readJsonFile(await codexPath())
      if (current === undefined || codexHasRotatingTokens(current)) return undefined
      return canonicalCredentialJson(current)
    },
    apply: async (content) => {
      const path = await codexPath()
      const current = await readJsonFile(path)
      // Never clobber a live ChatGPT login with a ferried API key.
      if (codexHasRotatingTokens(current)) return
      await atomicWriteJson(path, JSON.parse(content) as Record<string, unknown>)
    },
    applyDelete: async () => {
      const path = await codexPath()
      const current = await readJsonFile(path)
      if (current === undefined || codexHasRotatingTokens(current)) return
      await rm(path, { force: true })
    }
  }

  const devinPath = async (): Promise<string> => {
    const env = await config.resolveEnv()
    const dataHome = env.XDG_DATA_HOME?.trim()
    const base = dataHome ? dataHome : join(env.HOME ?? homedir(), ".local", "share")
    return join(base, "devin", "credentials.toml")
  }

  // Devin's credentials.toml is a static API key plus fixed endpoint URLs —
  // no token family, so the file travels verbatim (TOML, not JSON, hence a
  // raw-text source rather than a merge class).
  const devin: CredentialSource = {
    id: "devin-credentials-file",
    tombstoneOnAbsence: true,
    read: async () => {
      try {
        return await readFile(await devinPath(), "utf8")
      } catch (cause) {
        if ((cause as NodeJS.ErrnoException).code === "ENOENT") return undefined
        throw cause
      }
    },
    apply: async (content) => {
      const path = await devinPath()
      await mkdir(dirname(path), { recursive: true, mode: 0o700 })
      const temporary = `${path}.codevisor-${process.pid}.tmp`
      await writeFile(temporary, content, { encoding: "utf8", mode: 0o600 })
      await rename(temporary, path)
      await chmod(path, 0o600)
    },
    applyDelete: async () => {
      await rm(await devinPath(), { force: true })
    }
  }

  return [
    mergeClassSource("pi-auth", piPath, (type) => type === "api_key"),
    mergeClassSource("opencode-auth", openCodePath, (type) => type !== "oauth"),
    codex,
    devin
  ]
}
