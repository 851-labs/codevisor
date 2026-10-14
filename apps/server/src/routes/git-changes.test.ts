import { execFileSync } from "node:child_process"
import { mkdtempSync, realpathSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"

import { describe, expect, it, onTestFinished, vi } from "vitest"

import { jsonRequest, start, tempDirs } from "../test-support.js"

const tempFolder = (prefix: string): string => {
  const folder = realpathSync(mkdtempSync(join(tmpdir(), prefix)))
  tempDirs.push(folder)
  return folder
}

describe("git changes routes", () => {
  it("lists, stages, unstages, and discards changes, answering with the new status", async () => {
    // The machine's own git configuration must not decide what is ignored,
    // and a folder outside a repository must not find one above the temp dir.
    vi.stubEnv("GIT_CONFIG_GLOBAL", "/dev/null")
    vi.stubEnv("GIT_CONFIG_NOSYSTEM", "1")
    vi.stubEnv("GIT_CEILING_DIRECTORIES", realpathSync(tmpdir()))
    onTestFinished(() => {
      vi.unstubAllEnvs()
    })
    const { server } = await start()
    const repo = tempFolder("codevisor-changes-")
    execFileSync("git", ["init", "--quiet", "-b", "main"], { cwd: repo })
    writeFileSync(join(repo, "notes.txt"), "draft\n")
    const query = `path=${encodeURIComponent(repo)}`

    expect(await jsonRequest(server, `/v1/fs/git/status?${query}`)).toEqual({
      status: 200,
      body: {
        repositoryRoot: repo,
        branch: "main",
        entries: [{ path: "notes.txt", unstaged: "untracked" }],
        truncated: false
      }
    })

    const staged = await jsonRequest(server, "/v1/fs/git/stage", {
      method: "POST",
      body: JSON.stringify({ path: repo, files: ["notes.txt"] })
    })
    expect(staged).toMatchObject({
      status: 200,
      body: { entries: [{ path: "notes.txt", staged: "added" }] }
    })

    const post = (route: string, body: unknown) =>
      jsonRequest(server, route, { method: "POST", body: JSON.stringify(body) })
    expect(await post("/v1/fs/git/unstage", { path: repo })).toMatchObject({
      status: 200,
      body: { entries: [{ path: "notes.txt", unstaged: "untracked" }] }
    })
    // A discard names its files; without any it changes nothing.
    expect(await post("/v1/fs/git/discard", { path: repo })).toMatchObject({
      status: 200,
      body: { entries: [{ path: "notes.txt", unstaged: "untracked" }] }
    })
    expect(await post("/v1/fs/git/discard", { path: repo, files: ["missing.txt"] })).toMatchObject({
      status: 422,
      body: { code: "git_failed" }
    })
    expect(await post("/v1/fs/git/stage", { files: [] })).toMatchObject({ status: 400 })

    writeFileSync(join(repo, "other.txt"), "other\n")
    const diff = await jsonRequest(
      server,
      `/v1/fs/git/diff?${query}&mode=unstaged&file=${encodeURIComponent("notes.txt")}`
    )
    expect(diff).toMatchObject({ status: 200, body: { files: [{ path: "notes.txt" }] } })
    expect((diff.body as { files: ReadonlyArray<unknown> }).files).toHaveLength(1)

    const outside = tempFolder("codevisor-unversioned-")
    expect(
      await jsonRequest(server, `/v1/fs/git/status?path=${encodeURIComponent(outside)}`)
    ).toMatchObject({ status: 422, body: { code: "not_git_repository" } })
  })
})
