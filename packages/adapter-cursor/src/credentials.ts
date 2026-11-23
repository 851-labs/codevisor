import { execFile } from "node:child_process"
import { readFile } from "node:fs/promises"
import { homedir } from "node:os"
import { join } from "node:path"
import { promisify } from "node:util"

export interface CursorCredentialStore {
  readonly platform: NodeJS.Platform
  readonly env: NodeJS.ProcessEnv
  readonly readKeychain: (service: string, account: string) => Promise<string | undefined>
  readonly readText: (path: string) => Promise<string | undefined>
}

const keychainService = "cursor-access-token"
const keychainAccount = "cursor-user"
const keychainTimeoutMs = 5_000

export const cursorAccessToken = async (
  store: CursorCredentialStore
): Promise<string | undefined> => {
  if (store.platform === "darwin") {
    const fromKeychain = await store.readKeychain(keychainService, keychainAccount)
    if (fromKeychain !== undefined) return fromKeychain
  }
  return fileToken(store)
}

export const systemCursorCredentialStore = (env: NodeJS.ProcessEnv): CursorCredentialStore => ({
  platform: process.platform,
  env,
  readKeychain: readKeychainPassword,
  readText: (path) => readFile(path, "utf8").catch(() => undefined)
})

export const cursorAuthFilePath = (platform: NodeJS.Platform, env: NodeJS.ProcessEnv): string => {
  const home = env.HOME ?? homedir()
  if (platform === "darwin") return join(home, ".cursor", "auth.json")
  if (platform === "win32") {
    return join(env.APPDATA ?? join(home, "AppData", "Roaming"), "Cursor", "auth.json")
  }
  return join(env.XDG_CONFIG_HOME ?? join(home, ".config"), "cursor", "auth.json")
}

const fileToken = async (store: CursorCredentialStore): Promise<string | undefined> => {
  const text = await store.readText(cursorAuthFilePath(store.platform, store.env))
  if (text === undefined) return undefined

  try {
    const token: unknown = JSON.parse(text).accessToken
    return typeof token === "string" && token.length > 0 ? token : undefined
  } catch {
    return undefined
  }
}

const readKeychainPassword = async (
  service: string,
  account: string
): Promise<string | undefined> => {
  try {
    const { stdout } = await promisify(execFile)(
      "/usr/bin/security",
      ["find-generic-password", "-s", service, "-a", account, "-w"],
      { timeout: keychainTimeoutMs }
    )
    const password = stdout.trim()
    return password.length > 0 ? password : undefined
  } catch {
    return undefined
  }
}
