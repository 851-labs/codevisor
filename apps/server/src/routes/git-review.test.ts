import { execFileSync } from "node:child_process"
import { chmodSync, mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"

import { describe, expect, it, vi } from "vitest"

import {
  jsonRequest,
  makeServices,
  run,
  runningServers,
  startWithApp,
  tempDirs,
  waitFor
} from "../test-support.js"

const tempFolder = (prefix: string): string => {
  const folder = mkdtempSync(join(tmpdir(), prefix))
  tempDirs.push(folder)
  return folder
}

describe("git review routes", () => {
  it("serves reviews of a folder and snapshots it when a prompt starts a turn", async () => {
    const { agents, services } = await makeServices("server-a")
    const folder = tempFolder("codevisor-review-")
    execFileSync("git", ["init", "--quiet", "-b", "main"], { cwd: folder })
    execFileSync(
      "git",
      ["-c", "user.email=t@t", "-c", "user.name=t", "commit", "--allow-empty", "-m", "init"],
      { cwd: folder }
    )
    writeFileSync(join(folder, "notes.txt"), "draft\n")
    const project = await run(services.db.createProject({ folderPath: folder }))
    const session = await run(
      services.db.createSession({ projectId: project.id, harnessId: "codex" })
    )
    const server = await startWithApp(services)
    runningServers.push(server)
    const review = (query: string) => jsonRequest(server, `/v1/fs/git/${query}`)
    const path = encodeURIComponent(folder)

    const first = await review(`diff?path=${path}&mode=uncommitted`)
    expect(first).toEqual({
      status: 200,
      body: {
        mode: "uncommitted",
        repositoryRoot: execFileSync("git", ["rev-parse", "--show-toplevel"], {
          cwd: folder,
          encoding: "utf8"
        }).trim(),
        files: [
          {
            path: "notes.txt",
            status: "added",
            fingerprint: expect.any(String),
            oldText: null,
            newText: "draft\n"
          }
        ],
        truncated: false,
        revision: expect.any(String)
      }
    })
    const revision = encodeURIComponent((first.body as { revision: string }).revision)
    expect(await review(`diff?path=${path}&mode=uncommitted&revision=${revision}`)).toMatchObject({
      status: 200,
      body: { unchanged: true, files: [] }
    })
    expect(await review(`refs?path=${path}`)).toEqual({
      status: 200,
      body: {
        currentBranch: "main",
        defaultBase: "main",
        branches: [{ name: "main", remote: false }]
      }
    })
    const failures: ReadonlyArray<readonly [string, number, string]> = [
      [`diff?path=${path}&mode=lastTurn`, 404, "no_turn_snapshot"],
      [`diff?path=${path}&mode=everything`, 400, "invalid_mode"],
      [`diff?path=${path}&mode=branch&base=nope`, 422, "unknown_base"],
      [
        `refs?path=${encodeURIComponent(tempFolder("codevisor-plain-"))}`,
        422,
        "not_git_repository"
      ],
      [`refs?path=${path}%2Fmissing`, 404, "not_found"],
      [`refs?path=${path}%2Fnotes.txt`, 400, "not_a_directory"],
      ["refs", 400, "invalid_path"]
    ]
    for (const [query, status, code] of failures) {
      expect(await review(query), query).toMatchObject({ status, body: { code } })
    }

    // The snapshot is taken before the agent sees the prompt, so once the
    // agent has it, "last turn" compares against the folder as it was then.
    await jsonRequest(server, `/v1/sessions/${session.id}/prompt`, {
      body: JSON.stringify({ text: "edit notes" }),
      method: "POST"
    })
    await waitFor(() => agents.prompts.length === 1)
    writeFileSync(join(folder, "notes.txt"), "edited\n")
    expect(await review(`diff?path=${path}&mode=lastTurn`)).toMatchObject({
      status: 200,
      body: {
        files: [
          {
            path: "notes.txt",
            status: "modified",
            fingerprint: expect.any(String),
            oldText: "draft\n",
            newText: "edited\n"
          }
        ]
      }
    })
  })

  it("answers a folder's pull request from gh, sharing one lookup across asks", async () => {
    const { services } = await makeServices("server-a")
    const folder = tempFolder("codevisor-pr-")
    execFileSync("git", ["init", "--quiet", "-b", "feature/badge"], { cwd: folder })
    const bin = join(tempFolder("codevisor-gh-"), "bin")
    mkdirSync(bin)
    const calls = join(bin, "calls")
    writeFileSync(
      join(bin, "gh"),
      `#!/bin/sh\necho call >> '${calls}'\necho '{"number":7,"title":"Badge","state":"OPEN","isDraft":true,"url":"https://github.com/o/r/pull/7"}'\n`
    )
    chmodSync(join(bin, "gh"), 0o755)
    const env = { ...process.env, PATH: `${bin}:${process.env.PATH ?? ""}` }
    const server = await startWithApp({ ...services, resolveGitEnvironment: async () => env })
    runningServers.push(server)
    const lookup = () =>
      jsonRequest(server, `/v1/fs/git/pull-request?path=${encodeURIComponent(folder)}`)

    const expected = {
      status: 200,
      body: {
        pullRequest: {
          number: 7,
          title: "Badge",
          state: "open",
          isDraft: true,
          url: "https://github.com/o/r/pull/7",
          checks: "none"
        }
      }
    }
    expect(await Promise.all([lookup(), lookup()])).toEqual([expected, expected])
    expect(await lookup()).toEqual(expected)
    expect(readFileSync(calls, "utf8").trim().split("\n")).toHaveLength(1)
  })

  it("asks gh again once a pull request answer is a minute old", async () => {
    const { services } = await makeServices("server-a")
    const folder = tempFolder("codevisor-pr-stale-")
    execFileSync("git", ["init", "--quiet", "-b", "feature/stale"], { cwd: folder })
    const bin = join(tempFolder("codevisor-gh-"), "bin")
    mkdirSync(bin)
    const calls = join(bin, "calls")
    writeFileSync(
      join(bin, "gh"),
      `#!/bin/sh\necho call >> '${calls}'\necho '{"number":8,"title":"Stale","state":"OPEN","isDraft":false,"url":"u"}'\n`
    )
    chmodSync(join(bin, "gh"), 0o755)
    const env = { ...process.env, PATH: `${bin}:${process.env.PATH ?? ""}` }
    const server = await startWithApp({ ...services, resolveGitEnvironment: async () => env })
    runningServers.push(server)
    const lookup = () =>
      jsonRequest(server, `/v1/fs/git/pull-request?path=${encodeURIComponent(folder)}`)

    await lookup()
    const later = Date.now() + 61_000
    const clock = vi.spyOn(Date, "now").mockReturnValue(later)
    try {
      await lookup()
    } finally {
      clock.mockRestore()
    }
    expect(readFileSync(calls, "utf8").trim().split("\n")).toHaveLength(2)
  })
})
