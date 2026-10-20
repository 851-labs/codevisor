import { execFileSync } from "node:child_process"
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"

import { Worktree } from "@codevisor/api"
import { Schema } from "effect"
import { describe, expect, it, onTestFinished, vi } from "vitest"

import { archiveJobs } from "../archive-jobs.js"
import { jsonRequest, makeServices, startWithApp, tempDirs } from "../test-support.js"

const tempFolder = (prefix: string): string => {
  const folder = mkdtempSync(join(tmpdir(), prefix))
  tempDirs.push(folder)
  return folder
}

describe("workspace git routes", () => {
  it("answers an archived worktree's branch and pull request after its folder is gone", async () => {
    vi.stubEnv("CODEVISOR_WORKTREES_ROOT", tempFolder("codevisor-workspace-git-"))
    const { services } = await makeServices("server-a")
    const repoFolder = tempFolder("codevisor-workspace-git-repo-")
    execFileSync("git", ["init", "--quiet", "-b", "main"], { cwd: repoFolder })
    execFileSync(
      "git",
      ["-c", "user.email=t@t", "-c", "user.name=t", "commit", "--allow-empty", "-m", "init"],
      { cwd: repoFolder }
    )
    const bin = join(tempFolder("codevisor-gh-"), "bin")
    mkdirSync(bin)
    const ghCalls = join(bin, "calls")
    writeFileSync(ghCalls, "")
    writeFileSync(
      join(bin, "gh"),
      `#!/bin/sh\necho "$3" >> "${ghCalls}"\necho "{\\"number\\":9,\\"title\\":\\"$3\\",\\"state\\":\\"MERGED\\",\\"isDraft\\":false,\\"url\\":\\"u\\"}"\n`
    )
    chmodSync(join(bin, "gh"), 0o755)
    const env = { ...process.env, PATH: `${bin}:${process.env.PATH ?? ""}` }
    const appServices = { ...services, resolveGitEnvironment: async () => env }
    const server = await startWithApp(appServices)
    await jsonRequest(server, "/v1/projects", {
      body: JSON.stringify({ folderPath: repoFolder, id: "git-project" }),
      method: "POST"
    })
    const worktree = Schema.decodeUnknownSync(Worktree)(
      (
        await jsonRequest(server, "/v1/projects/git-project/worktrees", {
          body: JSON.stringify({ name: "sushi" }),
          method: "POST"
        })
      ).body
    )
    await jsonRequest(server, "/v1/workspaces/work", {
      body: JSON.stringify({
        projectId: "git-project",
        name: "Work",
        hasCustomName: false,
        rootDirectory: worktree.path
      }),
      method: "PUT"
    })
    const lookup = (query = "") => jsonRequest(server, `/v1/workspaces/work/git${query}`)
    const pullRequest = {
      number: 9,
      title: worktree.branch,
      state: "merged",
      isDraft: false,
      url: "u",
      checks: "none"
    }

    expect(await lookup()).toEqual({ status: 200, body: { branch: worktree.branch } })

    await jsonRequest(server, "/v1/workspaces/work", {
      body: JSON.stringify({ isArchived: true }),
      method: "PATCH"
    })
    await archiveJobs(appServices).idle()
    expect(existsSync(worktree.path)).toBe(false)

    expect(await lookup()).toEqual({ status: 200, body: { branch: worktree.branch } })
    expect(readFileSync(ghCalls, "utf8")).toBe("")
    expect(await lookup("?pullRequest=true")).toEqual({
      status: 200,
      body: { branch: worktree.branch, pullRequest }
    })
    expect(readFileSync(ghCalls, "utf8")).toBe(`${worktree.branch}\n`)

    await jsonRequest(server, "/v1/projects/git-project/worktrees", {
      body: JSON.stringify({ name: "sushi" }),
      method: "POST"
    })
    execFileSync("git", ["checkout", "--quiet", "-b", "someone-else"], { cwd: worktree.path })
    expect(await lookup()).toEqual({ status: 200, body: { branch: worktree.branch } })
    expect((await jsonRequest(server, "/v1/workspaces/missing/git")).status).toBe(404)
  })

  it("shows a reused worktree name only the pull requests opened from it", async () => {
    const { worktreeInWorkspace, answerWith, setArchived, pullRequests } =
      await sushiProjectWithFakeGh()
    const first = await worktreeInWorkspace("first")
    answerWith(9, "MERGED", "2026-02-01T10:00:00Z")
    await setArchived("first", true)

    vi.setSystemTime("2026-03-01T12:00:00Z")
    const reused = await worktreeInWorkspace("reused")
    expect(reused.branch).toBe(first.branch)
    expect(await pullRequests("reused", reused.path)).toEqual([
      { branch: reused.branch, pullRequest: null },
      { pullRequest: null }
    ])

    vi.setSystemTime("2026-03-01T12:05:00Z")
    answerWith(12, "OPEN", "2026-03-01T12:04:00Z")
    expect(await pullRequests("reused", reused.path)).toEqual([
      { branch: reused.branch, pullRequest: answered(12, "open") },
      { pullRequest: answered(12, "open") }
    ])
  })

  it("keeps a restored worktree's pull request from before it was archived", async () => {
    const { worktreeInWorkspace, answerWith, setArchived, pullRequests } =
      await sushiProjectWithFakeGh()
    const worktree = await worktreeInWorkspace("work")
    answerWith(9, "MERGED", "2026-02-01T10:00:00Z")
    await setArchived("work", true)

    vi.setSystemTime("2026-03-01T12:00:00Z")
    await setArchived("work", false)
    expect(existsSync(worktree.path)).toBe(true)
    expect(await pullRequests("work", worktree.path)).toEqual([
      { branch: worktree.branch, pullRequest: answered(9, "merged") },
      { pullRequest: answered(9, "merged") }
    ])
  })

  it("answers nothing for a workspace without a folder, a git checkout, or a worktree", async () => {
    const { services } = await makeServices("server-a")
    const server = await startWithApp(services)
    const folder = tempFolder("codevisor-workspace-git-plain-")
    await jsonRequest(server, "/v1/projects", {
      body: JSON.stringify({ folderPath: folder, id: "plain" }),
      method: "POST"
    })
    await jsonRequest(server, "/v1/workspaces/gone", {
      body: JSON.stringify({
        projectId: "plain",
        name: "Gone",
        hasCustomName: false,
        rootDirectory: join(folder, "missing")
      }),
      method: "PUT"
    })

    await jsonRequest(server, "/v1/workspaces/bare", {
      body: JSON.stringify({ projectId: "plain", name: "Bare", hasCustomName: false }),
      method: "PUT"
    })
    await jsonRequest(server, "/v1/workspaces/plain", {
      body: JSON.stringify({
        projectId: "plain",
        name: "Plain",
        hasCustomName: false,
        rootDirectory: folder
      }),
      method: "PUT"
    })

    for (const id of ["gone", "bare", "plain"]) {
      expect(await jsonRequest(server, `/v1/workspaces/${id}/git`)).toEqual({
        status: 200,
        body: { branch: null }
      })
    }
    for (const id of ["gone", "plain"]) {
      expect(await jsonRequest(server, `/v1/workspaces/${id}/git?pullRequest=true`)).toEqual({
        status: 200,
        body: { branch: null, pullRequest: null }
      })
    }
  })
})

const answered = (number: number, state: string) => ({
  number,
  title: "t",
  state,
  isDraft: false,
  url: "u",
  checks: "none"
})

const sushiProjectWithFakeGh = async () => {
  vi.useFakeTimers({ toFake: ["Date"] })
  onTestFinished(() => {
    vi.useRealTimers()
  })
  vi.setSystemTime("2026-02-01T09:00:00Z")
  vi.stubEnv("CODEVISOR_WORKTREES_ROOT", tempFolder("codevisor-workspace-git-"))
  const { services } = await makeServices("server-a")
  const repoFolder = tempFolder("codevisor-workspace-git-repo-")
  execFileSync("git", ["init", "--quiet", "-b", "main"], { cwd: repoFolder })
  execFileSync(
    "git",
    ["-c", "user.email=t@t", "-c", "user.name=t", "commit", "--allow-empty", "-m", "init"],
    { cwd: repoFolder }
  )
  const bin = join(tempFolder("codevisor-gh-"), "bin")
  mkdirSync(bin)
  const ghAnswer = join(bin, "answer")
  writeFileSync(join(bin, "gh"), `#!/bin/sh\ncat "${ghAnswer}"\n`)
  chmodSync(join(bin, "gh"), 0o755)
  const env = { ...process.env, PATH: `${bin}:${process.env.PATH ?? ""}` }
  const appServices = { ...services, resolveGitEnvironment: async () => env }
  const server = await startWithApp(appServices)
  await jsonRequest(server, "/v1/projects", {
    body: JSON.stringify({ folderPath: repoFolder, id: "git-project" }),
    method: "POST"
  })

  const answerWith = (number: number, state: string, createdAt: string) =>
    writeFileSync(
      ghAnswer,
      JSON.stringify({ number, title: "t", state, isDraft: false, url: "u", createdAt })
    )
  const worktreeInWorkspace = async (id: string) => {
    const worktree = Schema.decodeUnknownSync(Worktree)(
      (
        await jsonRequest(server, "/v1/projects/git-project/worktrees", {
          body: JSON.stringify({ name: "sushi" }),
          method: "POST"
        })
      ).body
    )
    await jsonRequest(server, `/v1/workspaces/${id}`, {
      body: JSON.stringify({
        projectId: "git-project",
        name: id,
        hasCustomName: false,
        rootDirectory: worktree.path
      }),
      method: "PUT"
    })
    return worktree
  }
  const setArchived = async (id: string, isArchived: boolean) => {
    await jsonRequest(server, `/v1/workspaces/${id}`, {
      body: JSON.stringify({ isArchived }),
      method: "PATCH"
    })
    await archiveJobs(appServices).idle()
  }
  const pullRequests = async (id: string, path: string) => [
    (await jsonRequest(server, `/v1/workspaces/${id}/git?pullRequest=true`)).body,
    (await jsonRequest(server, `/v1/fs/git/pull-request?path=${encodeURIComponent(path)}`)).body
  ]
  return { answerWith, worktreeInWorkspace, setArchived, pullRequests }
}
