import { execFileSync } from "node:child_process"
import { createServer, type Server, type Socket } from "node:net"
import { tmpdir } from "node:os"
import { join } from "node:path"

import { describe, expect, it, onTestFinished } from "vitest"

import { alternateCloneUrl, cloneUrlHost, parseCloneProgress, probeRemote } from "./git-clone.js"
import { expectInstanceOf, makeGitRepo, testTempDir } from "./git-test-support.js"
import { CloneError, cloneRepository, gitRemoteUrl } from "./git.js"

const silentGitDaemon = async (): Promise<string> => {
  const sockets: Array<Socket> = []
  const server: Server = createServer((socket) => {
    sockets.push(socket)
  })
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve))
  onTestFinished(async () => {
    for (const socket of sockets) socket.destroy()
    await new Promise((resolve) => server.close(resolve))
  })
  const address = server.address()
  if (address === null || typeof address === "string") throw new Error("No port")
  return `git://127.0.0.1:${String(address.port)}/widget.git`
}

describe("clone progress", () => {
  it("reads the stage, percent, counts and transfer from git's progress lines", () => {
    expect(parseCloneProgress("remote: Enumerating objects: 1234, done.")).toEqual({
      stage: "counting"
    })
    expect(
      parseCloneProgress("Receiving objects:  45% (556/1234), 1.50 MiB | 512.00 KiB/s")
    ).toEqual({
      stage: "receiving",
      percent: 45,
      completed: 556,
      total: 1234,
      bytes: 1_572_864,
      bytesPerSecond: 524_288
    })
    expect(parseCloneProgress("Receiving objects: 100% (1234/1234), 900 bytes, done.")).toEqual({
      stage: "receiving",
      percent: 100,
      completed: 1234,
      total: 1234,
      bytes: 900
    })
    expect(parseCloneProgress("Resolving deltas: 100% (80/80), done.")).toEqual({
      stage: "resolving",
      percent: 100,
      completed: 80,
      total: 80
    })
    expect(parseCloneProgress("Updating files:  12% (3/25)")).toEqual({
      stage: "checkout",
      percent: 12,
      completed: 3,
      total: 25
    })
    expect(parseCloneProgress("fatal: repository not found")).toBeUndefined()
  })
})

describe("clone URLs", () => {
  it("swaps SSH and HTTPS forms on standard ports", () => {
    expect(alternateCloneUrl("git@github.com:acme/widget.git")).toBe(
      "https://github.com/acme/widget.git"
    )
    expect(alternateCloneUrl("ssh://git@gitlab.com/acme/widget.git")).toBe(
      "https://gitlab.com/acme/widget.git"
    )
    expect(alternateCloneUrl("https://token@github.com/acme/widget")).toBe(
      "git@github.com:acme/widget"
    )
    expect(alternateCloneUrl("ssh://git@example.com:2222/acme/widget.git")).toBeUndefined()
    expect(alternateCloneUrl("https://example.com:8443/acme/widget.git")).toBeUndefined()
    expect(alternateCloneUrl("file:///tmp/widget")).toBeUndefined()
    expect(alternateCloneUrl("/srv/git/widget")).toBeUndefined()
  })

  it("finds the host a clone authenticates against", () => {
    expect(cloneUrlHost("git@GitHub.com:acme/widget.git")).toBe("github.com")
    expect(cloneUrlHost("https://gitlab.example.com/acme/widget")).toBe("gitlab.example.com")
    expect(cloneUrlHost("file:///tmp/widget")).toBeUndefined()
    expect(cloneUrlHost("/srv/git/widget")).toBeUndefined()
  })
})

describe("remote probes", () => {
  it("reports a reachable remote and classifies a missing one", async () => {
    const { repo } = makeGitRepo()

    const reachable = await probeRemote(`file://${repo}`)
    const missing = await probeRemote("file:///nonexistent-origin.git")

    expect(reachable).toEqual({ ok: true, message: "" })
    expect(missing).toMatchObject({ ok: false, code: "invalid_url" })
  })

  it("gives up on a remote that never answers and stops when cancelled", async () => {
    const url = await silentGitDaemon()
    const controller = new AbortController()

    const timedOut = await probeRemote(url, process.env, undefined, 100)
    const cancelled = probeRemote(url, process.env, controller.signal)
    controller.abort()

    expect(timedOut).toEqual({
      ok: false,
      code: "network",
      message: "Timed out reaching the repository"
    })
    expect(await cancelled).toEqual({ ok: false, code: "cancelled", message: "Clone cancelled" })
  })
})

describe("cancelling a clone", () => {
  it("rejects as cancelled before and during the clone", async () => {
    const url = await silentGitDaemon()
    const destination = join(testTempDir(join(tmpdir(), "codevisor-clone-cancel-")), "checkout")
    const before = new AbortController()
    before.abort()
    const during = new AbortController()

    const early = await cloneRepository(
      url,
      destination,
      undefined,
      process.env,
      before.signal
    ).catch((cause: unknown) => cause)
    const running = cloneRepository(url, destination, undefined, process.env, during.signal).catch(
      (cause: unknown) => cause
    )
    during.abort()

    expect(expectInstanceOf(early, CloneError).code).toBe("cancelled")
    expect(expectInstanceOf(await running, CloneError).code).toBe("cancelled")
  })
})

describe("repository identity", () => {
  it("reads the configured remote, not the URL an insteadOf rule rewrites it to", async () => {
    const { repo } = makeGitRepo()
    const git = (...args: Array<string>) => execFileSync("git", args, { cwd: repo })
    git("remote", "add", "origin", "https://github.com/acme/widget.git")
    git("config", "url.http://10.0.0.5:8080/.insteadOf", "https://github.com/")

    expect(await gitRemoteUrl(repo)).toBe("https://github.com/acme/widget.git")
  })
})
