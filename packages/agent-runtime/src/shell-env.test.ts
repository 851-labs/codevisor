import { describe, expect, it } from "vitest"
import { fallbackPathDirectories, resolveShellEnv, runShellCommand } from "./shell-env.js"

const envOutput = (path: string): string => `HOME=/Users/tester\nPATH=${path}\nLANG=en_US.UTF-8\n`

describe("resolveShellEnv", () => {
  it("merges probed PATH first, then base PATH, then fallbacks, deduped", async () => {
    const invocations: Array<readonly [string, ReadonlyArray<string>, number]> = []
    const resolved = await resolveShellEnv({
      base: { PATH: "/usr/bin:/base-only", SHELL: "/bin/fish" },
      platform: "darwin",
      homedir: "/Users/tester",
      runShell: (shell, args, timeoutMs) => {
        invocations.push([shell, args, timeoutMs])
        return Promise.resolve(envOutput("/probe-first:/usr/bin:/opt/homebrew/bin"))
      }
    })

    expect(invocations).toEqual([["/bin/fish", ["-ilc", "/usr/bin/env"], 5000]])
    const directories = (resolved.PATH ?? "").split(":")
    // Probed ordering wins; duplicates from base/fallbacks collapse.
    expect(directories.slice(0, 3)).toEqual(["/probe-first", "/usr/bin", "/opt/homebrew/bin"])
    expect(directories).toContain("/base-only")
    expect(directories).toContain("/Users/tester/.local/bin")
    expect(directories.filter((directory) => directory === "/usr/bin")).toHaveLength(1)
    // Non-PATH keys pass through untouched.
    expect(resolved.SHELL).toBe("/bin/fish")
  })

  it("takes the last PATH line from env output and ignores other lines", async () => {
    const resolved = await resolveShellEnv({
      base: { PATH: "" },
      platform: "darwin",
      homedir: "/Users/tester",
      runShell: () => Promise.resolve("PATH=/stale\nOTHER=x\nPATH=/fresh\n")
    })
    expect((resolved.PATH ?? "").split(":")[0]).toBe("/fresh")
    expect(resolved.PATH).not.toContain("/stale")
  })

  it.each([
    ["probe rejects", (): Promise<string> => Promise.reject(new Error("timed out"))],
    ["probe output is empty", (): Promise<string> => Promise.resolve("")],
    ["probe output has no PATH line", (): Promise<string> => Promise.resolve("HOME=/x\n")]
  ])("degrades to base + fallbacks when %s", async (_name, runShell) => {
    const resolved = await resolveShellEnv({
      base: { PATH: "/base-only" },
      platform: "darwin",
      homedir: "/Users/tester",
      runShell
    })
    const directories = (resolved.PATH ?? "").split(":")
    expect(directories[0]).toBe("/base-only")
    expect(directories).toEqual(["/base-only", ...fallbackPathDirectories("/Users/tester")])
  })

  it("defaults the shell per platform when SHELL is unset or empty", async () => {
    const shells: Array<string> = []
    const runShell = (shell: string): Promise<string> => {
      shells.push(shell)
      return Promise.resolve(envOutput("/probed"))
    }
    await resolveShellEnv({ base: {}, platform: "darwin", homedir: "/h", runShell })
    await resolveShellEnv({ base: { SHELL: "" }, platform: "linux", homedir: "/h", runShell })
    expect(shells).toEqual(["/bin/zsh", "/bin/bash"])
  })

  it("passes through untouched on win32", async () => {
    const base = { PATH: "C:\\Windows", SHELL: "" }
    await expect(resolveShellEnv({ base, platform: "win32" })).resolves.toBe(base)
  })

  it("honors a custom timeout", async () => {
    let seen = 0
    await resolveShellEnv({
      base: {},
      platform: "linux",
      homedir: "/h",
      timeoutMs: 123,
      runShell: (_shell, _args, timeoutMs) => {
        seen = timeoutMs
        return Promise.resolve(envOutput("/probed"))
      }
    })
    expect(seen).toBe(123)
  })

  it("uses the real shell runner by default, degrading when the shell is missing", async () => {
    // SHELL points at a binary that cannot exist, so the default execFile
    // runner fails fast — covering the default-runner path without ever
    // spawning a real login shell in tests.
    const resolved = await resolveShellEnv({
      base: { PATH: "/base-only", SHELL: "/nonexistent-shell-for-test" },
      platform: "linux",
      homedir: "/h"
    })
    expect((resolved.PATH ?? "").split(":")).toEqual([
      "/base-only",
      ...fallbackPathDirectories("/h")
    ])
  })

  it("defaults base/platform/homedir from the process without probing a login shell", async () => {
    // Only inject runShell: base=process.env, platform=process.platform,
    // homedir=os.homedir() — the merge must still include the fallback dirs.
    const resolved = await resolveShellEnv({
      runShell: () => Promise.resolve(envOutput("/probed-default"))
    })
    if (process.platform === "win32") {
      expect(resolved).toBe(process.env)
    } else {
      expect(resolved.PATH).toContain("/probed-default")
      expect(resolved.PATH).toContain("/.local/bin")
    }
  })
})

describe("runShellCommand", () => {
  it("resolves stdout from a real process", async () => {
    // /bin/sh -c is not a login shell — no user rc files run in tests.
    await expect(runShellCommand("/bin/sh", ["-c", "printf 'PATH=/x\\n'"], 5000)).resolves.toBe(
      "PATH=/x\n"
    )
  })

  it("rejects on spawn failure", async () => {
    await expect(
      runShellCommand("/nonexistent-shell-for-test", ["-c", "true"], 5000)
    ).rejects.toThrow()
  })

  it("rejects when the command exceeds the timeout", async () => {
    await expect(runShellCommand("/bin/sh", ["-c", "sleep 5"], 50)).rejects.toThrow()
  })
})
