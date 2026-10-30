import { mkdir, mkdtemp, rm, stat, writeFile } from "node:fs/promises"
import { tmpdir, userInfo } from "node:os"
import { join } from "node:path"

import { describe, expect, it, onTestFinished, vi } from "vitest"

import {
  claudeKeychainAccount,
  claudeKeychainService,
  forgetClaudeProfileLogin
} from "./claude-profile-login.js"
import type { HarnessAuthExec } from "./harness-auth-types.js"

const profile = async () => {
  const directory = await mkdtemp(join(tmpdir(), "claude-profile-login-"))
  onTestFinished(() => rm(directory, { force: true, recursive: true }))
  return directory
}

const securityExit = (code: number) => Object.assign(new Error("security failed"), { code })

describe("forgetting a Claude profile login", () => {
  it("deletes only the profile's hashed Keychain item and its credentials file", async () => {
    const directory = await profile()
    await writeFile(join(directory, ".credentials.json"), "{}")
    const exec = vi.fn<HarnessAuthExec>(async () => ({ stdout: "", stderr: "" }))

    const removed = await forgetClaudeProfileLogin({
      directory,
      env: { USER: "alice" },
      exec,
      platform: "darwin"
    })

    expect(removed).toBe(true)
    expect(exec).toHaveBeenCalledExactlyOnceWith(
      "/usr/bin/security",
      ["delete-generic-password", "-s", claudeKeychainService(directory, false), "-a", "alice"],
      expect.anything()
    )
    expect(claudeKeychainService("/tmp/claude", false)).toBe("Claude Code-credentials-21493821")
    await expect(stat(join(directory, ".credentials.json"))).rejects.toThrow()
  })

  it("reports nothing removed when the profile holds no login", async () => {
    const exec = vi.fn<HarnessAuthExec>(async () => {
      throw securityExit(44)
    })

    const removed = await forgetClaudeProfileLogin({
      directory: await profile(),
      env: { USER: "alice" },
      exec,
      platform: "darwin"
    })

    expect(removed).toBe(false)
  })

  it("surfaces Keychain failures other than a missing item", async () => {
    const exec = vi.fn<HarnessAuthExec>(async () => {
      throw securityExit(51)
    })

    await expect(
      forgetClaudeProfileLogin({ directory: await profile(), env: {}, exec, platform: "darwin" })
    ).rejects.toThrow("security failed")
  })

  it("surfaces a credentials file it cannot remove", async () => {
    const directory = await profile()
    await mkdir(join(directory, ".credentials.json"))
    const exec = vi.fn<HarnessAuthExec>()

    await expect(
      forgetClaudeProfileLogin({ directory, env: {}, exec, platform: "darwin" })
    ).rejects.toThrow()
    expect(exec).not.toHaveBeenCalled()
  })

  it("leaves the Keychain alone off macOS", async () => {
    const exec = vi.fn<HarnessAuthExec>()

    await forgetClaudeProfileLogin({ directory: await profile(), env: {}, exec, platform: "linux" })

    expect(exec).not.toHaveBeenCalled()
  })

  it.each<[NodeJS.ProcessEnv, string]>([
    [{ USER: "alice" }, "alice"],
    [{ USER: "alice smith" }, "claude-code-user"],
    [{ USER: "" }, userInfo().username]
  ])("names the Keychain account the way Claude Code does for %j", (env, account) => {
    expect(claudeKeychainAccount(env)).toBe(account)
  })
})
