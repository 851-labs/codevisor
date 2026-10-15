import { execFileSync } from "node:child_process"
import { chmodSync, existsSync, mkdirSync, mkdtempSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"

import { Worktree } from "@codevisor/api"
import { Schema } from "effect"
import { describe, expect, it, vi } from "vitest"

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
    writeFileSync(
      join(bin, "gh"),
      `#!/bin/sh\necho "{\\"number\\":9,\\"title\\":\\"$3\\",\\"state\\":\\"MERGED\\",\\"isDraft\\":false,\\"url\\":\\"u\\"}"\n`
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
    const lookup = (kind: string) => jsonRequest(server, `/v1/workspaces/work/git/${kind}`)
    const pullRequest = {
      number: 9,
      title: worktree.branch,
      state: "merged",
      isDraft: false,
      url: "u",
      checks: "none"
    }

    expect(await lookup("branch")).toEqual({ status: 200, body: { branch: worktree.branch } })

    await jsonRequest(server, "/v1/workspaces/work", {
      body: JSON.stringify({ isArchived: true }),
      method: "PATCH"
    })
    await archiveJobs(appServices).idle()
    expect(existsSync(worktree.path)).toBe(false)

    expect(await lookup("branch")).toEqual({ status: 200, body: { branch: worktree.branch } })
    expect(await lookup("pull-request")).toEqual({ status: 200, body: { pullRequest } })

    await jsonRequest(server, "/v1/projects/git-project/worktrees", {
      body: JSON.stringify({ name: "sushi" }),
      method: "POST"
    })
    execFileSync("git", ["checkout", "--quiet", "-b", "someone-else"], { cwd: worktree.path })
    expect(await lookup("branch")).toEqual({ status: 200, body: { branch: worktree.branch } })
    expect((await jsonRequest(server, "/v1/workspaces/missing/git/branch")).status).toBe(404)
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
      expect(await jsonRequest(server, `/v1/workspaces/${id}/git/branch`)).toEqual({
        status: 200,
        body: { branch: null }
      })
    }
    expect(await jsonRequest(server, "/v1/workspaces/gone/git/pull-request")).toEqual({
      status: 200,
      body: { pullRequest: null }
    })
  })
})
