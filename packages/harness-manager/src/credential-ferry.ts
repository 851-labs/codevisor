import { chmod, mkdir, readFile, rename, rm, writeFile } from "node:fs/promises"
import { homedir } from "node:os"
import { dirname, join } from "node:path"

import lockfile from "proper-lockfile"

import { openCodeAuthPath } from "./opencode-auth.js"

export interface CredentialSource {
  readonly id: string
  readonly read: (sharedContent?: string) => Promise<string | undefined>
  readonly localOverrides?: () => Promise<ReadonlyArray<string>>
  readonly apply: (content: string) => Promise<void>
  readonly applyDelete?: () => Promise<void>
  readonly tombstoneOnAbsence: boolean
}

export interface CredentialFerryConfig {
  readonly resolveEnv: () => Promise<NodeJS.ProcessEnv>
  readonly localProviders?: (harness: "pi" | "opencode") => Promise<ReadonlyArray<string>>
}

export const canonicalCredentialJson = (value: Record<string, unknown>): string =>
  JSON.stringify(
    Object.fromEntries(Object.entries(value).toSorted(([a], [b]) => a.localeCompare(b)))
  )

export const readJsonFile = async (path: string): Promise<Record<string, unknown> | undefined> => {
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

export const atomicWriteJson = async (
  path: string,
  value: Record<string, unknown>
): Promise<void> => {
  await mkdir(dirname(path), { recursive: true, mode: 0o700 })
  const temporary = `${path}.codevisor-${process.pid}.tmp`
  await writeFile(temporary, JSON.stringify(value, null, 2), { encoding: "utf8", mode: 0o600 })
  await rename(temporary, path)
  await chmod(path, 0o600)
}

export const withFileLock = async (path: string, body: () => Promise<void>): Promise<void> => {
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

const mergeClassSource = (
  id: string,
  pathFor: () => Promise<string>,
  travels: (type: string | undefined) => boolean,
  localProviders: () => Promise<ReadonlyArray<string>> = async () => []
): CredentialSource => ({
  id,
  tombstoneOnAbsence: false,
  localOverrides: async () => [
    ...(await localProviders()),
    ...Object.entries((await readJsonFile(await pathFor())) ?? {})
      .filter(([, value]) => !travels(credentialType(value)))
      .map(([id]) => id)
  ],
  read: async (sharedContent) => {
    const current = await readJsonFile(await pathFor())
    if (current === undefined) return undefined
    const local = new Set(await localProviders())
    const subset = Object.fromEntries(
      Object.entries(current).filter(
        ([id, value]) => !local.has(id) && travels(credentialType(value))
      )
    )
    const shared =
      sharedContent === undefined ? {} : (JSON.parse(sharedContent) as Record<string, unknown>)
    for (const [id, value] of Object.entries(current)) {
      if ((local.has(id) || !travels(credentialType(value))) && id in shared)
        subset[id] = shared[id]
    }
    for (const id of local) if (id in shared) subset[id] = shared[id]
    return canonicalCredentialJson(subset)
  },
  apply: async (content) => {
    const incoming = JSON.parse(content) as Record<string, unknown>
    const local = new Set(await localProviders())
    for (const id of local) delete incoming[id]
    const path = await pathFor()
    await withFileLock(path, async () => {
      /* v8 ignore next */
      const current = (await readJsonFile(path)) ?? {}
      const preserved = Object.fromEntries(
        Object.entries(current).filter(
          ([id, value]) => local.has(id) || !travels(credentialType(value))
        )
      )
      await atomicWriteJson(path, { ...incoming, ...preserved })
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
    localOverrides: async () =>
      codexHasRotatingTokens(await readJsonFile(await codexPath())) ? ["*"] : [],
    read: async () => {
      const current = await readJsonFile(await codexPath())
      if (current === undefined || codexHasRotatingTokens(current)) return undefined
      return canonicalCredentialJson(current)
    },
    apply: async (content) => {
      const path = await codexPath()
      const current = await readJsonFile(path)
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
    mergeClassSource(
      "pi-auth",
      piPath,
      (type) => type === "api_key",
      config.localProviders && (() => config.localProviders!("pi"))
    ),
    mergeClassSource(
      "opencode-auth",
      openCodePath,
      (type) => type !== "oauth",
      config.localProviders && (() => config.localProviders!("opencode"))
    ),
    codex,
    devin
  ]
}
