import { execFileSync } from "node:child_process"
import { mkdirSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"

import { describe, expect, it } from "vitest"

import { hasCommits, needsInitialCommit, PublishError, publishToRemote } from "./git-publish.js"
import { expectInstanceOf, makeGitRepo, testTempDir } from "./git-test-support.js"
import { CloneError, gitRemoteUrl } from "./git.js"

const identity = {
  GIT_AUTHOR_NAME: "Test",
  GIT_AUTHOR_EMAIL: "test@example.test",
  GIT_COMMITTER_NAME: "Test",
  GIT_COMMITTER_EMAIL: "test@example.test"
}

const withConfig = (entries: Record<string, string>): NodeJS.ProcessEnv => {
  const pairs = Object.entries(entries)
  return {
    ...process.env,
    GIT_CONFIG_COUNT: String(pairs.length),
    ...Object.fromEntries(
      pairs.flatMap(([key, value], index) => [
        [`GIT_CONFIG_KEY_${String(index)}`, key],
        [`GIT_CONFIG_VALUE_${String(index)}`, value]
      ])
    )
  }
}

const git = (cwd: string, ...args: Array<string>): string =>
  execFileSync("git", args, { cwd, encoding: "utf8", env: { ...process.env, ...identity } }).trim()

const bareRemote = (): string => {
  const root = testTempDir(join(tmpdir(), "codevisor-publish-remote-"))
  const bare = join(root, "widget.git")
  execFileSync("git", ["init", "--bare", "-b", "main", bare], { stdio: "ignore" })
  return bare
}

const plainFolder = (): string => {
  const folder = join(testTempDir(join(tmpdir(), "codevisor-publish-")), "notes")
  mkdirSync(join(folder, "apps", "web"), { recursive: true })
  writeFileSync(join(folder, "README.md"), "notes\n")
  writeFileSync(join(folder, ".env"), "TOKEN=1\n")
  writeFileSync(join(folder, "apps", "web", ".env.local"), "LOCAL=1\n")
  return folder
}

describe("publishing a folder to a new remote", () => {
  it("commits a plain folder without its env files, adds origin and pushes with upstream", async () => {
    const folder = plainFolder()
    const remote = bareRemote()
    expect(await needsInitialCommit(folder)).toBe(true)

    await publishToRemote(folder, `file://${remote}`, {
      initialize: true,
      env: { ...process.env, ...identity }
    })

    expect(await gitRemoteUrl(folder)).toBe(`file://${remote}`)
    expect(await needsInitialCommit(folder)).toBe(false)
    const branch = git(folder, "rev-parse", "--abbrev-ref", "HEAD")
    expect(git(remote, "ls-tree", "-r", "--name-only", branch)).toBe("README.md")
    expect(git(folder, "rev-parse", "--abbrev-ref", "@{upstream}")).toMatch(/^origin\//)
  })

  it("pushes an existing history untouched and starts a nested folder as its own repository", async () => {
    const { repo } = makeGitRepo(true)
    const remote = bareRemote()
    const nested = join(repo, "nested")
    mkdirSync(nested)

    await publishToRemote(repo, `file://${remote}`, { initialize: true })

    expect(git(remote, "rev-list", "--count", "main")).toBe("1")
    expect(await needsInitialCommit(nested)).toBe(true)
    expect(await hasCommits(repo)).toBe(true)
  })

  it("leaves the folder untouched when the remote can't be reached", async () => {
    const { repo } = makeGitRepo()

    const failure = await publishToRemote(repo, "file:///nowhere/widget.git", {
      initialize: false
    }).catch((cause: unknown) => cause)

    expectInstanceOf(failure, CloneError)
    expect(await gitRemoteUrl(repo)).toBeUndefined()
  })

  it("reports a rejected or refused push and removes the origin it added", async () => {
    const remote = bareRemote()
    const { repo: other } = makeGitRepo(true)
    git(other, "push", `file://${remote}`, "main")
    const { repo } = makeGitRepo()

    const failure = await publishToRemote(repo, `file://${remote}`, { initialize: false }).catch(
      (cause: unknown) => cause
    )

    expect(expectInstanceOf(failure, PublishError).code).toBe("push_rejected")
    expect(await gitRemoteUrl(repo)).toBeUndefined()

    const declining = bareRemote()
    writeFileSync(join(declining, "hooks", "pre-receive"), "#!/bin/sh\nexit 1\n", { mode: 0o755 })
    const refused = await publishToRemote(repo, `file://${declining}`, {
      initialize: false
    }).catch((cause: unknown) => cause)
    expect(expectInstanceOf(refused, PublishError).code).toBeUndefined()
  })

  it("explains a missing git identity and other commit failures", async () => {
    const remote = bareRemote()
    const missingIdentity = await publishToRemote(plainFolder(), `file://${remote}`, {
      initialize: true,
      env: withConfig({ "user.useConfigOnly": "true" })
    }).catch((cause: unknown) => cause)
    const unsigned = await publishToRemote(plainFolder(), `file://${remote}`, {
      initialize: true,
      env: { ...withConfig({ "commit.gpgsign": "true", "gpg.program": "false" }), ...identity }
    }).catch((cause: unknown) => cause)

    expect(expectInstanceOf(missingIdentity, PublishError).code).toBe("identity_missing")
    expect(expectInstanceOf(unsigned, PublishError).code).toBeUndefined()
  })
})
