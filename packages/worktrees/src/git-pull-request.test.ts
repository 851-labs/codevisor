import { execFileSync } from "node:child_process"
import { chmodSync, existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs"
import { join } from "node:path"

import { describe, expect, it } from "vitest"

import {
  findGitPullRequest,
  gitPullRequest,
  parseGitPullRequest,
  rollUpChecks
} from "./git-pull-request.js"
import { makeGitRepo } from "./git-test-support.js"

const fakeGh = (root: string, script: string): { env: NodeJS.ProcessEnv; argsFile: string } => {
  const bin = join(root, "bin")
  mkdirSync(bin)
  const argsFile = join(root, "gh-args")
  writeFileSync(
    join(bin, "gh"),
    `#!/bin/sh\nprintf '%s\\n' "$@" "prompt=$GH_PROMPT_DISABLED" > '${argsFile}'\n${script}\n`
  )
  chmodSync(join(bin, "gh"), 0o755)
  return { env: { ...process.env, PATH: `${bin}:${process.env.PATH ?? ""}` }, argsFile }
}

describe("gitPullRequest", () => {
  it("asks gh about the current branch and normalizes its answer", async () => {
    const { root, repo } = makeGitRepo()
    execFileSync("git", ["checkout", "-q", "-b", "feature/badge"], { cwd: repo })
    const answer = {
      number: 42,
      title: "Add the PR badge",
      state: "MERGED",
      isDraft: false,
      url: "https://github.com/o/r/pull/42"
    }
    const { env, argsFile } = fakeGh(root, `echo '${JSON.stringify(answer)}'`)

    expect(await gitPullRequest(repo, env)).toEqual({ ...answer, state: "merged", checks: "none" })
    const args = readFileSync(argsFile, "utf8").split("\n")
    expect(args.slice(0, 3)).toEqual(["pr", "view", "feature/badge"])
    expect(args).toContain("prompt=1")
  })

  it("is null when gh has no pull request for the branch", async () => {
    const { root, repo } = makeGitRepo()
    const { env } = fakeGh(root, `echo 'no pull requests found for branch "main"' >&2; exit 1`)

    expect(await gitPullRequest(repo, env)).toBeNull()
  })

  it("tells a branch without a pull request apart from a lookup that failed", async () => {
    const { root, repo } = makeGitRepo()
    const missing = fakeGh(root, `echo 'no pull requests found for branch "main"' >&2; exit 1`)
    expect(await findGitPullRequest(repo, missing.env, "main")).toBeNull()

    const offline = makeGitRepo()
    const failing = fakeGh(offline.root, `echo 'error connecting to api.github.com' >&2; exit 1`)
    expect(await findGitPullRequest(offline.repo, failing.env, "main")).toBeUndefined()
    expect(await gitPullRequest(offline.repo, failing.env, "main")).toBeNull()
  })

  it("asks gh about a branch it is given instead of the checkout's", async () => {
    const { root, repo } = makeGitRepo()
    const answer = { number: 7, title: "t", state: "OPEN", isDraft: false, url: "u" }
    const { env, argsFile } = fakeGh(root, `echo '${JSON.stringify(answer)}'`)

    expect(await gitPullRequest(repo, env, "codevisor/archived")).toMatchObject({ number: 7 })
    expect(readFileSync(argsFile, "utf8").split("\n").slice(0, 3)).toEqual([
      "pr",
      "view",
      "codevisor/archived"
    ])
  })

  it("is null on a detached HEAD without asking gh", async () => {
    const { root, repo } = makeGitRepo()
    execFileSync("git", ["checkout", "-q", "--detach"], { cwd: repo })
    const { env, argsFile } = fakeGh(root, `echo '{}'`)

    expect(await gitPullRequest(repo, env)).toBeNull()
    expect(existsSync(argsFile)).toBe(false)
  })
})

describe("parseGitPullRequest", () => {
  it("rejects malformed or unknown answers", () => {
    expect(parseGitPullRequest("not json")).toBeNull()
    expect(parseGitPullRequest("null")).toBeNull()
    expect(parseGitPullRequest("42")).toBeNull()
    expect(
      parseGitPullRequest(
        JSON.stringify({ number: 1, title: "t", state: 1, isDraft: false, url: "u" })
      )
    ).toBeNull()
    expect(
      parseGitPullRequest(
        JSON.stringify({ number: 1, title: "t", state: "LOCKED", isDraft: false, url: "u" })
      )
    ).toBeNull()
    expect(
      parseGitPullRequest(
        JSON.stringify({ number: "1", title: "t", state: "OPEN", isDraft: false, url: "u" })
      )
    ).toBeNull()
  })

  it("keeps a draft's flag", () => {
    expect(
      parseGitPullRequest(
        JSON.stringify({ number: 7, title: "WIP", state: "OPEN", isDraft: true, url: "u" })
      )
    ).toEqual({ number: 7, title: "WIP", state: "open", isDraft: true, url: "u", checks: "none" })
  })
})

const run = (status: string, conclusion: string | null = null) => ({
  __typename: "CheckRun",
  status,
  conclusion
})
const commitStatus = (state: string) => ({ __typename: "StatusContext", state })

describe("rollUpChecks", () => {
  it("is none without checks", () => {
    expect(rollUpChecks([])).toBe("none")
    expect(rollUpChecks(undefined)).toBe("none")
  })

  it("lets any failure win over running and passing checks", () => {
    expect(
      rollUpChecks([run("COMPLETED", "SUCCESS"), run("IN_PROGRESS"), run("COMPLETED", "FAILURE")])
    ).toBe("failing")
    expect(rollUpChecks([commitStatus("SUCCESS"), commitStatus("ERROR")])).toBe("failing")
  })

  it("is pending while anything is unfinished", () => {
    expect(rollUpChecks([run("COMPLETED", "SUCCESS"), run("QUEUED")])).toBe("pending")
    expect(rollUpChecks([commitStatus("PENDING")])).toBe("pending")
  })

  it("passes when everything finished without failing", () => {
    expect(
      rollUpChecks([
        run("COMPLETED", "SUCCESS"),
        run("COMPLETED", "SKIPPED"),
        commitStatus("SUCCESS")
      ])
    ).toBe("passing")
  })
})
