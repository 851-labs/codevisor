import { readFile, rm } from "node:fs/promises"
import { join } from "node:path"

import { claudeKeychainAccount } from "./claude-profile-login.js"
import { atomicWriteJson } from "./credential-ferry.js"
import type { HarnessAuthExec } from "./harness-auth-types.js"
import { errnoCode, parseJsonRecord } from "./json-values.js"
import type { SharedTokenBundle } from "./shared-credential-types.js"
import { readNativeOAuth } from "./shared-oauth-providers.js"

export interface ClaudeMachineLocation {
  readonly directory: string
  readonly keychainService: string
  readonly isDefault: boolean
}

export interface ClaudeMachineLoginOptions {
  readonly location: ClaudeMachineLocation
  readonly env: NodeJS.ProcessEnv
  readonly exec: HarnessAuthExec
  readonly platform: string
}

export const readClaudeMachineLogin = (
  options: ClaudeMachineLoginOptions
): Promise<SharedTokenBundle | undefined> =>
  readNativeOAuth({
    harnessId: "claude-code",
    directory: options.location.directory,
    isDefault: options.location.isDefault,
    keychainService: options.location.keychainService,
    ownership: "managed",
    env: options.env,
    exec: options.exec,
    platform: options.platform
  })

export const signOutClaudeMachineLogin = async (
  options: ClaudeMachineLoginOptions
): Promise<void> => {
  await stripCredentialsFile(join(options.location.directory, ".credentials.json"))
  if (options.platform === "darwin") await stripKeychainItem(keychainOf(options))
}

const loginKey = "claudeAiOauth"
const keychainItemNotFound = 44
const securityTimeoutMs = 5_000

interface Keychain {
  readonly service: string
  readonly account: string
  readonly exec: HarnessAuthExec
}

type CredentialDocument = Record<string, unknown>

const keychainOf = (options: ClaudeMachineLoginOptions): Keychain => ({
  service: options.location.keychainService,
  account: claudeKeychainAccount(options.env),
  exec: options.exec
})

const holdsLogin = (document: CredentialDocument | undefined): document is CredentialDocument =>
  document !== undefined && loginKey in document

const withoutLogin = (document: CredentialDocument): CredentialDocument => {
  const { [loginKey]: _login, ...remainder } = document
  return remainder
}

const isEmpty = (document: CredentialDocument): boolean => Object.keys(document).length === 0

const stripCredentialsFile = async (path: string): Promise<void> => {
  const document = await readCredentialsFile(path)
  if (!holdsLogin(document)) return

  const remainder = withoutLogin(document)
  if (isEmpty(remainder)) await rm(path)
  else await atomicWriteJson(path, remainder)
}

const readCredentialsFile = async (path: string): Promise<CredentialDocument | undefined> => {
  try {
    return parseJsonRecord(await readFile(path, "utf8"))
  } catch (cause) {
    if (errnoCode(cause) === "ENOENT") return undefined
    throw cause
  }
}

const stripKeychainItem = async (keychain: Keychain): Promise<void> => {
  const document = await readKeychainItem(keychain)
  if (!holdsLogin(document)) return

  const remainder = withoutLogin(document)
  if (isEmpty(remainder)) await deleteKeychainItem(keychain)
  else await writeKeychainItem(keychain, remainder)

  if (holdsLogin(await readKeychainItem(keychain)))
    throw new Error("Claude Code's login is still in the Keychain")
}

const readKeychainItem = async (keychain: Keychain): Promise<CredentialDocument | undefined> => {
  try {
    const { stdout } = await keychain.exec(
      "/usr/bin/security",
      ["find-generic-password", "-a", keychain.account, "-s", keychain.service, "-w"],
      { timeout: securityTimeoutMs, maxBuffer: 1_000_000 }
    )
    return parsedRecord(stdout)
  } catch (cause) {
    if (isMissingItem(cause)) return undefined
    throw cause
  }
}

const deleteKeychainItem = async (keychain: Keychain): Promise<void> => {
  await keychain.exec(
    "/usr/bin/security",
    ["delete-generic-password", "-a", keychain.account, "-s", keychain.service],
    { timeout: securityTimeoutMs }
  )
}

const writeKeychainItem = async (
  keychain: Keychain,
  document: CredentialDocument
): Promise<void> => {
  const hex = Buffer.from(JSON.stringify(document), "utf8").toString("hex")
  const command = `add-generic-password -U -a "${keychain.account}" -s "${keychain.service}" -X "${hex}"\n`
  await keychain.exec("/usr/bin/security", ["-i"], { timeout: securityTimeoutMs, input: command })
}

const parsedRecord = (raw: string): CredentialDocument | undefined => {
  try {
    return parseJsonRecord(raw)
  } catch {
    return undefined
  }
}

const isMissingItem = (cause: unknown): boolean => errnoCode(cause) === keychainItemNotFound
