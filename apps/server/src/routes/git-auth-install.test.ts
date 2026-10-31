import { chmodSync, existsSync, writeFileSync } from "node:fs"
import { join } from "node:path"

import { describe, expect, it } from "vitest"

import { jsonRequest } from "../test-support.js"
import {
  fakeGhRelease,
  isolatedGitEnv,
  startServer,
  tempDir,
  type TestServer
} from "./project-setup-test-support.js"
import { field } from "./response-test-support.js"

const deviceFlowGh = `case "$1 $2" in
  "auth login")
    echo "! First copy your one-time code: AB12-CD34" >&2
    echo "Open this URL to continue in your web browser: https://github.com/login/device" >&2
    exec sleep 30 ;;
  *) exit 1 ;;
esac`

const startSignIn = async (server: TestServer) =>
  jsonRequest(server, "/v1/git/auth/login", {
    body: JSON.stringify({ host: "github.com" }),
    method: "POST"
  })

const settledFlow = async (server: TestServer, flowId: string): Promise<unknown> => {
  for (;;) {
    const flow = await jsonRequest(server, `/v1/git/auth/login/${flowId}`)
    if (field(flow.body, "state") !== "starting") return flow.body
    await new Promise((resolve) => setTimeout(resolve, 20))
  }
}

describe("git sign-in without the host's CLI", () => {
  it("installs GitHub CLI first, then shows the device code", async () => {
    const release = await fakeGhRelease(deviceFlowGh)
    const { server } = await startServer(isolatedGitEnv(), release.gitHosts)

    const before = await jsonRequest(server, "/v1/git/auth/status?host=github.com")
    const started = await startSignIn(server)
    const flowId = String(field(started.body, "id"))
    const waiting = await settledFlow(server, flowId)
    const after = await jsonRequest(server, "/v1/git/auth/status?host=github.com")
    await jsonRequest(server, `/v1/git/auth/login/${flowId}`, { method: "DELETE" })

    expect(before.body).toMatchObject({ cliInstalled: false, signedIn: false })
    expect(started.body).toMatchObject({ state: "starting", installing: true })
    expect(waiting).toMatchObject({
      state: "waiting",
      userCode: "AB12-CD34",
      verificationUrl: "https://github.com/login/device"
    })
    expect(waiting).not.toHaveProperty("installing")
    expect(after.body).toMatchObject({ cliInstalled: true, signedIn: false })
    expect(existsSync(join(release.toolsDir, "bin", "gh"))).toBe(true)
    expect(release.downloads()).toBe(1)
  })

  it("fails the sign-in when the download doesn't check out", async () => {
    const release = await fakeGhRelease(deviceFlowGh, { checksum: "0".repeat(64) })
    const { server } = await startServer(isolatedGitEnv(), release.gitHosts)

    const started = await startSignIn(server)
    const failed = await settledFlow(server, String(field(started.body, "id")))

    expect(failed).toEqual({
      id: field(started.body, "id"),
      host: "github.com",
      provider: "github",
      state: "error",
      message: "The GitHub CLI download didn't match its checksum."
    })
    expect(existsSync(join(release.toolsDir, "bin", "gh"))).toBe(false)
  })

  it("never starts gh's sign-in when it's cancelled during the install", async () => {
    const loginStarted = join(tempDir("codevisor-gh-login-"), "started")
    const release = await fakeGhRelease(`touch "${loginStarted}"\n${deviceFlowGh}`)
    const { server } = await startServer(isolatedGitEnv(), release.gitHosts)

    const started = await startSignIn(server)
    const flowId = String(field(started.body, "id"))
    await jsonRequest(server, `/v1/git/auth/login/${flowId}`, { method: "DELETE" })
    while (!existsSync(join(release.toolsDir, "bin", "gh"))) {
      await new Promise((resolve) => setTimeout(resolve, 20))
    }
    await new Promise((resolve) => setTimeout(resolve, 200))
    const flow = await jsonRequest(server, `/v1/git/auth/login/${flowId}`)

    expect(started.body).toMatchObject({ installing: true })
    expect(flow.body).toMatchObject({ state: "cancelled" })
    expect(flow.body).not.toHaveProperty("installing")
    expect(existsSync(loginStarted)).toBe(false)
  })

  it("uses a gh that's already on PATH without downloading one", async () => {
    const release = await fakeGhRelease(deviceFlowGh)
    const bin = tempDir("codevisor-own-gh-")
    const env = isolatedGitEnv(bin)
    writeFileSync(
      join(bin, "gh"),
      `#!/bin/sh\n[ "$1" = "--version" ] && echo "gh version 2.98.0" && exit 0\n${deviceFlowGh}\n`
    )
    chmodSync(join(bin, "gh"), 0o755)
    const { server } = await startServer(env, release.gitHosts)

    const started = await startSignIn(server)
    await jsonRequest(server, `/v1/git/auth/login/${String(field(started.body, "id"))}`, {
      method: "DELETE"
    })

    expect(started.body).toMatchObject({ state: "waiting", userCode: "AB12-CD34" })
    expect(started.body).not.toHaveProperty("installing")
    expect(release.downloads()).toBe(0)
    expect(existsSync(release.toolsDir)).toBe(false)
  })
})
