import { chmodSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"

import { describe, expect, it, onTestFinished } from "vitest"

import { testTempDir } from "./git-test-support.js"
import {
  GitMissingError,
  gitExecutable,
  gitInstallation,
  isGitWorkTree,
  useGitEnvironment,
  type GitInstallation
} from "./git.js"

const missing: GitInstallation = { state: "missing" }

const binDirectory = (): string => testTempDir(join(tmpdir(), "codevisor-git-command-"))

const installGit = (bin: string): string => {
  const git = join(bin, "git")
  writeFileSync(git, "#!/bin/sh\n")
  chmodSync(git, 0o755)
  return git
}

const useMachinePath = (path: string): void => {
  useGitEnvironment(() => Promise.resolve({ PATH: path }))
  onTestFinished(() => useGitEnvironment(() => Promise.resolve(process.env)))
}

describe("the machine's Git", () => {
  it("is the one on the machine's own PATH for commands that bring no PATH", async () => {
    const bin = binDirectory()
    const git = installGit(bin)
    useMachinePath(bin)

    expect(await gitInstallation()).toEqual({ state: "ready", path: git })
    expect(gitExecutable()).toBe(git)
    expect(gitExecutable({ GIT_TERMINAL_PROMPT: "0" })).toBe(git)
  })

  it("gives way to the Git on a command's own PATH", () => {
    const projectBin = binDirectory()
    const projectGit = installGit(projectBin)
    useMachinePath(binDirectory())

    expect(gitExecutable({ PATH: projectBin })).toBe(projectGit)
  })

  it("is refused while it isn't there, and found once installed, with no restart", async () => {
    const bin = binDirectory()
    useMachinePath(bin)

    expect(await gitInstallation()).toEqual(missing)
    expect(() => gitExecutable()).toThrow(GitMissingError)

    const git = installGit(bin)
    expect(gitExecutable()).toBe(git)
  })

  it("fails a work tree check instead of calling the folder not a repository", async () => {
    useMachinePath(binDirectory())
    await gitInstallation()

    await expect(isGitWorkTree(process.cwd())).rejects.toBeInstanceOf(GitMissingError)
  })
})
