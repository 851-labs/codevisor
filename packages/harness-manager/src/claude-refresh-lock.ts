import { mkdir, realpath } from "node:fs/promises"
import { join } from "node:path"

import lockfile, { type LockOptions } from "proper-lockfile"

import { errnoCode } from "./json-values.js"

export class ClaudeRefreshLockBusy extends Error {
  constructor() {
    super("Claude Code is refreshing its login")
  }
}

export interface ClaudeRefreshLock {
  readonly isCompromised: () => boolean
}

const claudeRefreshLockPath = (directory: string): string => join(directory, ".oauth_refresh.lock")

export const withClaudeRefreshLock = async <T>(
  directory: string,
  body: (lock: ClaudeRefreshLock) => Promise<T>
): Promise<T> => {
  await mkdir(directory, { recursive: true })
  let compromised = false
  /* v8 ignore next 3 */
  const options = lockOptions(() => {
    compromised = true
  })

  const releaseCurrent = await acquire(options(claudeRefreshLockPath(directory)))
  try {
    const releaseLegacy = await acquireLegacy(options(await legacyLockPath(directory)))
    try {
      return await body({ isCompromised: () => compromised })
    } finally {
      await releaseQuietly(releaseLegacy)
    }
  } finally {
    await releaseQuietly(releaseCurrent)
  }
}

type Release = () => Promise<void>

type ClaudeLockOptions = LockOptions & { readonly lockfilePath: string }

const staleMs = 60_000
const updateMs = 5_000

const lockOptions =
  (onCompromised: () => void) =>
  (lockfilePath: string): ClaudeLockOptions => ({
    lockfilePath,
    realpath: false,
    stale: staleMs,
    update: updateMs,
    retries: 0,
    onCompromised
  })

const legacyLockPath = async (directory: string): Promise<string> =>
  `${await realpath(directory)}.lock`

const acquire = async (options: ClaudeLockOptions): Promise<Release> => {
  try {
    return await lockfile.lock(options.lockfilePath, options)
  } catch (cause) {
    if (errnoCode(cause) === "ELOCKED") throw new ClaudeRefreshLockBusy()
    throw cause
  }
}

const acquireLegacy = async (options: ClaudeLockOptions): Promise<Release | undefined> => {
  try {
    return await acquire(options)
  } catch (cause) {
    if (cause instanceof ClaudeRefreshLockBusy) throw cause
    return undefined
  }
}

const releaseQuietly = async (release: Release | undefined): Promise<void> => {
  /* v8 ignore next */
  await release?.().catch(() => undefined)
}
