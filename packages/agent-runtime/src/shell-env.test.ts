import { describe, expect, it } from "vitest"
import {
  fallbackPathDirectories,
  nvmBinDirectories,
  resolveShellEnv,
  runShellCommand
} from "./shell-env.js"

const envOutput = (path: string): string => `HOME=/Users/tester\nPATH=${path}\nLANG=en_US.UTF-8\n`

describe("resolveShellEnv", () => {
  it("merges probed PATH first, then base PATH, then fallbacks, deduped", async () => {
    const invocations: Array<readonly [string, ReadonlyArray<string>, number]> = []
    const resolved = await resolveShellEnv({
      base: { PATH: "/usr/bin:/base-only", SHELL: "/bin/fish" },
      platform: "darwin",
      homedir: "/Users/tester",
      executableExists: () => true,
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
    const options = {
      homedir: "/h",
      runShell,
      userShell: () => undefined,
      executableExists: () => true
    }
    await resolveShellEnv({ base: {}, platform: "darwin" as const, ...options })
    await resolveShellEnv({ base: { SHELL: "" }, platform: "linux" as const, ...options })
    expect(shells).toEqual(["/bin/zsh", "/bin/bash"])
  })

  it("falls back to the passwd shell when $SHELL is unset, skipping missing shells", async () => {
    const shells: Array<string> = []
    const runShell = (shell: string): Promise<string> => {
      shells.push(shell)
      return Promise.resolve(envOutput("/probed"))
    }
    await resolveShellEnv({
      base: {},
      platform: "linux",
      homedir: "/h",
      runShell,
      userShell: () => "/etc/shells/fish",
      executableExists: (path) => path === "/etc/shells/fish"
    })
    // $SHELL set but not installed: skip it in favor of the platform default.
    await resolveShellEnv({
      base: { SHELL: "/gone" },
      platform: "linux",
      homedir: "/h",
      runShell,
      userShell: () => undefined,
      executableExists: (path) => path === "/bin/bash"
    })
    expect(shells).toEqual(["/etc/shells/fish", "/bin/bash"])
  })

  it("skips the probe entirely when no usable shell exists", async () => {
    let probes = 0
    const resolved = await resolveShellEnv({
      base: { PATH: "/base-only" },
      platform: "linux",
      homedir: "/h",
      runShell: () => {
        probes += 1
        return Promise.resolve(envOutput("/probed"))
      },
      userShell: () => undefined,
      executableExists: () => false
    })
    expect(probes).toBe(0)
    expect((resolved.PATH ?? "").split(":")[0]).toBe("/base-only")
  })

  it("includes Linux install dirs in the fallbacks and appends the newest nvm bin", async () => {
    const fallbacks = fallbackPathDirectories("/h")
    for (const directory of [
      "/snap/bin",
      "/h/.nix-profile/bin",
      "/h/.npm-global/bin",
      "/h/.deno/bin"
    ]) {
      expect(fallbacks).toContain(directory)
    }
    const resolved = await resolveShellEnv({
      base: { PATH: "" },
      platform: "linux",
      homedir: "/h",
      runShell: () => Promise.reject(new Error("no shell")),
      userShell: () => undefined,
      executableExists: () => true,
      listDirectory: (path) =>
        path === "/h/.nvm/versions/node"
          ? ["v22.1.0", "v24.15.0", "v24.2.1", "junk", ".DS_Store"]
          : []
    })
    expect(resolved.PATH).toContain("/h/.nvm/versions/node/v24.15.0/bin")
    expect(resolved.PATH).not.toContain("v22.1.0")
  })

  it("uses the real existence check to skip a missing $SHELL", async () => {
    const shells: Array<string> = []
    await resolveShellEnv({
      base: { SHELL: "/nonexistent-shell-for-test" },
      platform: "linux",
      homedir: "/h",
      userShell: () => undefined,
      runShell: (shell) => {
        shells.push(shell)
        return Promise.resolve(envOutput("/probed"))
      }
    })
    // Default accessSync check rejects the missing $SHELL and accepts the
    // platform default, which every supported host ships.
    expect(shells).toEqual(["/bin/bash"])
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
      homedir: "/h",
      executableExists: () => true
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

describe("nvmBinDirectories", () => {
  it("returns the newest installed version's bin dir", () => {
    expect(nvmBinDirectories("/h", () => ["v10.0.9", "v9.11.2", "v10.0.10", "notes.txt"])).toEqual([
      "/h/.nvm/versions/node/v10.0.10/bin"
    ])
  })

  it("returns nothing when nvm is absent or holds no versions", () => {
    expect(nvmBinDirectories("/h", () => [])).toEqual([])
    // Default lister tolerates a missing directory.
    expect(nvmBinDirectories("/nonexistent-home-for-test")).toEqual([])
  })
})
