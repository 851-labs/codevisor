import { existsSync, readFileSync } from "node:fs"
import { join } from "node:path"

import { describe, expect, it } from "vitest"

import { githubHost } from "./github-host.js"
import { parseGitPullRequest, rollUpChecks } from "./github-pull-request.js"
import { emptyEnv, fakeCli, testTempDir } from "./test-support.js"

const fakeGh = (script: string): { env: NodeJS.ProcessEnv; argsFile: string } => {
  const argsFile = join(testTempDir("codevisor-gh-args-"), "gh-args")
  const { env } = fakeCli(
    "gh",
    `printf '%s\\n' "$@" "prompt=$GH_PROMPT_DISABLED" "cwd=$(pwd -P)" > '${argsFile}'\n${script}`
  )
  return { env, argsFile }
}

const mergedAnswer = (createdAt: string | undefined): string =>
  JSON.stringify({ number: 9, title: "t", state: "MERGED", isDraft: false, url: "u", createdAt })

const findPullRequest = githubHost().findPullRequest

describe("GitHub pull request lookups", () => {
  it("asks gh about the branch in the checkout and normalizes its answer", async () => {
    const repo = testTempDir("codevisor-pr-repo-")
    const answer = {
      number: 42,
      title: "Add the PR badge",
      state: "MERGED",
      isDraft: false,
      url: "https://github.com/o/r/pull/42"
    }
    const { env, argsFile } = fakeGh(`echo '${JSON.stringify(answer)}'`)

    expect(await findPullRequest(repo, env, "feature/badge")).toEqual({
      ...answer,
      state: "merged",
      checks: "none"
    })
    const args = readFileSync(argsFile, "utf8").split("\n")
    expect(args.slice(0, 5)).toEqual([
      "pr",
      "view",
      "feature/badge",
      "--json",
      "number,title,state,isDraft,url,statusCheckRollup,createdAt"
    ])
    expect(args).toContain("prompt=1")
    expect(args.find((line) => line.startsWith("cwd="))).toMatch(/codevisor-pr-repo-/)
  })

  it("tells a branch without a pull request apart from a lookup that failed", async () => {
    const repo = testTempDir("codevisor-pr-repo-")
    const missing = fakeGh(`echo 'no pull requests found for branch "main"' >&2; exit 1`)
    const noOpen = fakeGh(`echo 'no open pull requests found for branch "main"' >&2; exit 1`)
    const failing = fakeGh(`echo 'error connecting to api.github.com' >&2; exit 1`)

    expect(await findPullRequest(repo, missing.env, "main")).toBeNull()
    expect(await findPullRequest(repo, noOpen.env, "main")).toBeNull()
    expect(await findPullRequest(repo, failing.env, "main")).toBeUndefined()
    expect(await findPullRequest(repo, emptyEnv(), "main")).toBeUndefined()
  })

  it("treats an answer it can't read as no pull request", async () => {
    const repo = testTempDir("codevisor-pr-repo-")
    const { env } = fakeGh(`echo 'not json'`)

    expect(await findPullRequest(repo, env, "main")).toBeNull()
  })

  it("ignores a pull request opened before the worktree claimed its branch", async () => {
    const owned = { name: "codevisor/sushi", ownedSince: "2026-03-01T12:00:00.000Z" }
    const ask = async (createdAt: string | undefined, branch = owned.name) => {
      const repo = testTempDir("codevisor-pr-repo-")
      const { env } = fakeGh(`echo '${mergedAnswer(createdAt)}'`)
      return findPullRequest(repo, env, branch, owned)
    }

    expect(await ask("2026-02-01T09:30:00Z")).toBeNull()
    expect(await ask("2026-03-01T12:04:00Z")).toMatchObject({ number: 9, state: "merged" })
    expect(await ask("2026-02-01T09:30:00Z", "codevisor/sushi-2")).toMatchObject({ number: 9 })
    expect(await ask(undefined)).toMatchObject({ number: 9 })
  })

  it("doesn't run anything when gh is missing", async () => {
    const repo = testTempDir("codevisor-pr-repo-")
    const { argsFile } = fakeGh("exit 0")

    expect(await findPullRequest(repo, emptyEnv(), "main")).toBeUndefined()
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
