import { chmod, mkdir, mkdtemp, realpath, rm, stat } from "node:fs/promises"
import { tmpdir } from "node:os"
import { dirname } from "node:path"
import { join } from "node:path"

import lockfile from "proper-lockfile"
import { describe, expect, it, onTestFinished, vi } from "vitest"

import {
  ClaudeRefreshLockBusy,
  claudeRefreshLockPath,
  withClaudeRefreshLock
} from "./claude-refresh-lock.js"

const configDirectory = async () => {
  const parent = await realpath(await mkdtemp(join(tmpdir(), "claude-refresh-lock-")))
  onTestFinished(() => rm(parent, { force: true, recursive: true }))
  const directory = join(parent, "claude")
  await mkdir(directory)
  return directory
}

const claudeCodeLocks = (directory: string) => [
  claudeRefreshLockPath(directory),
  `${directory}.lock`
]

const lockAsClaudeCode = (lockfilePath: string) =>
  lockfile.lock(lockfilePath, { lockfilePath, realpath: false, stale: 60_000 })

const readOnly = async (path: string) => {
  await chmod(path, 0o500)
  onTestFinished(() => chmod(path, 0o700))
}

const exists = (path: string) =>
  stat(path).then(
    () => true,
    () => false
  )

describe("Claude Code's refresh lock", () => {
  it("holds both of Claude Code's lock files while the body runs, then frees them", async () => {
    const directory = await configDirectory()

    const held = await withClaudeRefreshLock(directory, async (lock) => ({
      contended: await Promise.all(
        claudeCodeLocks(directory).map((path) =>
          lockAsClaudeCode(path).then(
            () => "acquired",
            (cause: NodeJS.ErrnoException) => cause.code
          )
        )
      ),
      compromised: lock.isCompromised()
    }))

    expect(held).toEqual({ contended: ["ELOCKED", "ELOCKED"], compromised: false })
    for (const path of claudeCodeLocks(directory)) expect(await exists(path)).toBe(false)
  })

  it.each([0, 1])("waits instead of running while Claude Code holds lock %i", async (held) => {
    const directory = await configDirectory()
    const release = await lockAsClaudeCode(claudeCodeLocks(directory)[held]!)
    onTestFinished(() => release())
    const body = vi.fn(async () => undefined)

    await expect(withClaudeRefreshLock(directory, body)).rejects.toBeInstanceOf(
      ClaudeRefreshLockBusy
    )

    expect(body).not.toHaveBeenCalled()
    for (const path of claudeCodeLocks(directory).filter((_, index) => index !== held))
      expect(await exists(path)).toBe(false)
  })

  it("still takes the current lock when, like Claude Code, it cannot create the legacy one", async () => {
    const directory = await configDirectory()
    await readOnly(dirname(directory))

    const ran = await withClaudeRefreshLock(directory, async () =>
      exists(claudeRefreshLockPath(directory))
    )

    expect(ran).toBe(true)
  })

  it("surfaces a lock it cannot create", async () => {
    const directory = await configDirectory()
    await readOnly(directory)

    await expect(withClaudeRefreshLock(directory, async () => undefined)).rejects.toMatchObject({
      code: "EACCES"
    })
  })
})
