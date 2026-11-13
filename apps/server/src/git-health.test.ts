import { chmodSync, mkdtempSync, rmSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"

import { useGitEnvironment } from "@codevisor/worktrees"
import { describe, expect, it, onTestFinished } from "vitest"

import { jsonRequest, makeServices, startWithApp } from "./test-support.js"

describe("server health", () => {
  it("reports Git missing until this machine has one on its PATH", async () => {
    const bin = emptyBinDirectory()
    useGitEnvironment(() => Promise.resolve({ PATH: bin }))
    onTestFinished(() => useGitEnvironment(() => Promise.resolve(process.env)))
    const server = await startWithApp((await makeServices()).services)

    expect((await jsonRequest(server, "/v1/health")).body).toMatchObject({
      ok: true,
      git: "missing"
    })

    installGit(bin)
    expect((await jsonRequest(server, "/v1/health")).body).toMatchObject({
      ok: true,
      git: "ready"
    })
  })
})

const emptyBinDirectory = (): string => {
  const directory = mkdtempSync(join(tmpdir(), "codevisor-git-health-"))
  onTestFinished(() => rmSync(directory, { force: true, recursive: true }))
  return directory
}

const installGit = (bin: string): void => {
  const git = join(bin, "git")
  writeFileSync(git, "#!/bin/sh\n")
  chmodSync(git, 0o755)
}
