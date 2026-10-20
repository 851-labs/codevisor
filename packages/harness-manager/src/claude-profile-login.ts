import { createHash } from "node:crypto"
import { rm } from "node:fs/promises"
import { userInfo } from "node:os"
import { join, resolve } from "node:path"

import type { HarnessAuthExec } from "./harness-auth-types.js"
import { errnoCode } from "./json-values.js"

export interface ClaudeProfileLoginOptions {
  readonly directory: string
  readonly env: NodeJS.ProcessEnv
  readonly exec: HarnessAuthExec
  readonly platform: string
}

export const claudeKeychainService = (directory: string, usesDefaultItem: boolean): string => {
  if (usesDefaultItem) return keychainServicePrefix
  return `${keychainServicePrefix}-${directoryHash(directory)}`
}

export const forgetClaudeProfileLogin = async (
  options: ClaudeProfileLoginOptions
): Promise<boolean> => {
  const removedFile = await removeCredentialsFile(options.directory)
  if (options.platform !== "darwin") return removedFile

  const removedItem = await deleteKeychainItem(options)
  return removedFile || removedItem
}

export const claudeKeychainAccount = (env: NodeJS.ProcessEnv): string => {
  const user = env.USER || userInfo().username
  return keychainAccountPattern.test(user) ? user : fallbackKeychainAccount
}

const keychainServicePrefix = "Claude Code-credentials"
const keychainAccountPattern = /^[a-zA-Z0-9._-]+$/
const fallbackKeychainAccount = "claude-code-user"
const keychainItemNotFound = 44
const securityTimeoutMs = 5_000

const directoryHash = (directory: string): string =>
  createHash("sha256").update(resolve(directory).normalize("NFC")).digest("hex").slice(0, 8)

const removeCredentialsFile = async (directory: string): Promise<boolean> => {
  try {
    await rm(join(directory, ".credentials.json"))
    return true
  } catch (cause) {
    if (errnoCode(cause) === "ENOENT") return false
    throw cause
  }
}

const deleteKeychainItem = async (options: ClaudeProfileLoginOptions): Promise<boolean> => {
  const service = claudeKeychainService(options.directory, false)
  const account = claudeKeychainAccount(options.env)
  try {
    await options.exec(
      "/usr/bin/security",
      ["delete-generic-password", "-s", service, "-a", account],
      { timeout: securityTimeoutMs }
    )
    return true
  } catch (cause) {
    if (isMissingItem(cause)) return false
    throw cause
  }
}

const isMissingItem = (cause: unknown): boolean => errnoCode(cause) === keychainItemNotFound
