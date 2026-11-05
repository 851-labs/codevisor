import { execFileSync } from "node:child_process"
import { mkdtempSync, rmSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"

import { expect, onTestFinished } from "vitest"

export const testTempDir = (prefix: string): string => {
  const root = mkdtempSync(prefix)
  onTestFinished(() => rmSync(root, { recursive: true, force: true }))
  return root
}

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

export const expectInstanceOf = <T>(
  value: unknown,
  type: abstract new (...args: never) => T
): T => {
  expect(value).toBeInstanceOf(type)
  if (!(value instanceof type)) throw new Error(`Expected an instance of ${type.name}`)
  return value
}
