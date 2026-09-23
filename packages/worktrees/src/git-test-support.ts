import { execFileSync } from "node:child_process"
import { mkdtempSync, rmSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"

import { afterEach, beforeEach, onTestFinished, vi } from "vitest"

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

// Each repository is built in place by Git rather than copied from a cached
// seed. The seed was shared mutable state: a `/tmp` tree held in a module-level
// map, deleted by a lifecycle hook, and recursively copied by every test. That
// copy walks the seed's `.git` one directory at a time, creating each level of
// the destination as it goes, so anything removing either tree mid-walk
// surfaces as a bare ENOENT on a `.git` subdirectory — which is how this
// failed on CI. `git init` has no such window: the repository either exists
// when the subprocess returns or the call throws.
//
// This costs roughly 40ms per repository against a seed copy's ~5ms. That is
// the deliberate trade: a few seconds across the suite to remove a class of
// flake, per the project's rule to delete shared mutable state rather than
// work around the race it creates.
export const makeGitRepo = (tracked = false): { root: string; repo: string } => {
  const root = testTempDir(join(tmpdir(), "codevisor-git-"))
  const repo = join(root, "repo")
  const git = (...args: string[]) =>
    execFileSync("git", ["-c", "user.name=Test", "-c", "user.email=test@example.test", ...args], {
      cwd: repo,
      stdio: "ignore"
    })
  execFileSync("git", ["init", "-b", "main", repo], { stdio: "ignore" })
  if (tracked) {
    writeFileSync(join(repo, "tracked.txt"), "original\n")
    git("add", "tracked.txt")
  }
  git("commit", "--allow-empty", "-m", "init")
  return { root, repo }
}
