import { execFileSync } from "node:child_process"
import { cpSync, mkdtempSync, rmSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { afterAll, afterEach, beforeEach, onTestFinished, vi } from "vitest"

beforeEach(() => {
  vi.stubEnv("GIT_CONFIG_GLOBAL", "/dev/null")
  vi.stubEnv("GIT_CONFIG_SYSTEM", "/dev/null")
  vi.stubEnv("GIT_CONFIG_NOSYSTEM", "1")
  vi.stubEnv("GIT_CONFIG_COUNT", "0")
  vi.stubEnv("GIT_TERMINAL_PROMPT", "0")
})
afterEach(() => vi.unstubAllEnvs())

export const testTempDir = (prefix: string): string => {
  const root = mkdtempSync(prefix)
  onTestFinished(() => rmSync(root, { recursive: true, force: true }))
  return root
}

// Copy an immutable seed instead of invoking init/add/commit for every case.
// Every test still owns a distinct .git directory, index, refs, and worktree.
const seeds = new Map<boolean, string>()
afterAll(() => {
  for (const seed of seeds.values()) rmSync(seed, { recursive: true, force: true })
})

export const makeGitRepo = (tracked = false): { root: string; repo: string } => {
  let seed = seeds.get(tracked)
  if (seed === undefined) {
    seed = mkdtempSync(join(tmpdir(), "codevisor-git-seed-"))
    const git = (...args: string[]) =>
      execFileSync("git", ["-c", "user.name=Test", "-c", "user.email=test@example.test", ...args], {
        cwd: seed,
        stdio: "ignore"
      })
    git("init", "-b", "main")
    if (tracked) {
      writeFileSync(join(seed, "tracked.txt"), "original\n")
      git("add", "tracked.txt")
    }
    git("commit", "--allow-empty", "-m", "init")
    seeds.set(tracked, seed)
  }
  const root = testTempDir(join(tmpdir(), "codevisor-git-"))
  const repo = join(root, "repo")
  cpSync(seed, repo, { recursive: true })
  return { root, repo }
}
