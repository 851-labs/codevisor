import { chmodSync, writeFileSync } from "node:fs"
import { join } from "node:path"

import type { GitAuthFlow } from "@codevisor/api"
import { describe, expect, it } from "vitest"

import { fakeCli, tempDir } from "../routes/project-setup-test-support.js"
import {
  makeGitAuthManager,
  parseDeviceCode,
  parseVerificationUrl,
  type GitAuthManager
} from "./git-auth.js"

const fastTimings = { codeWaitMs: 2_000, loginTimeoutMs: 60_000, retentionMs: 60_000 }

const settled = async (
  manager: GitAuthManager,
  flowId: string
): Promise<GitAuthFlow | undefined> => {
  for (;;) {
    const flow = manager.flow(flowId)
    if (flow === undefined || !["starting", "waiting"].includes(flow.state)) return flow
    await new Promise((resolve) => setTimeout(resolve, 20))
  }
}

const managerWith = (env: NodeJS.ProcessEnv, timings = fastTimings): GitAuthManager =>
  makeGitAuthManager(async () => env, timings)

describe("git sign-in flows", () => {
  it("signs in to GitLab with glab's device flow", async () => {
    const env = fakeCli(
      "glab",
      `case "$1 $2" in
  "auth status") [ -n "$GLAB_SIGNED_IN" ] && echo "Logged in to gitlab.com" >&2 && exit 0; exit 1 ;;
  "auth login")
    echo "! One-time code: GL12-AB34"
    echo "Open https://gitlab.com/oauth/device to continue."
    sleep 0.2
    echo "Waiting for authorization"
    exit 0 ;;
esac`
    )
    const manager = managerWith({ ...env, GLAB_SIGNED_IN: "1" })

    const started = await manager.begin("GitLab.com")
    const finished = await settled(manager, started.id)
    const status = await manager.status("gitlab.com")

    expect(started).toMatchObject({
      provider: "gitlab",
      userCode: "GL12-AB34",
      verificationUrl: "https://gitlab.com/oauth/device"
    })
    expect(finished).toEqual(expect.objectContaining({ state: "complete" }))
    expect(finished?.account).toBeUndefined()
    expect(status).toMatchObject({ cli: "glab", signedIn: true })
    expect(status.account).toBeUndefined()
  })

  it("reports failures from a missing, unrunnable, or failing CLI", async () => {
    const missing = managerWith({ ...process.env, PATH: tempDir("codevisor-empty-bin-") })
    const failing = managerWith(fakeCli("gh", 'echo "error connecting to github.com" >&2\nexit 1'))
    const unrunnableBin = tempDir("codevisor-unrunnable-")
    writeFileSync(join(unrunnableBin, "gh"), "#!/bin/sh\nexit 0\n")
    chmodSync(join(unrunnableBin, "gh"), 0o644)
    const unrunnable = managerWith({ ...process.env, PATH: unrunnableBin })

    const notInstalled = await missing.begin("github.com")
    const otherHost = await missing.begin("gitlab.com")
    const broken = await unrunnable.begin("github.com")
    const failed = await failing.begin("github.com")

    expect(await settled(missing, notInstalled.id)).toMatchObject({
      state: "error",
      message: "gh isn't installed on this machine"
    })
    expect(await settled(unrunnable, broken.id)).toMatchObject({ state: "error" })
    expect(missing.flow(notInstalled.id)?.message).toBe("gh isn't installed on this machine")
    expect(await settled(missing, otherHost.id)).toMatchObject({
      message: "glab isn't installed on this machine"
    })
    expect(await unrunnable.status("github.com")).toMatchObject({
      cliInstalled: true,
      signedIn: false
    })
    expect(await settled(failing, failed.id)).toMatchObject({
      state: "error",
      message: "gh sign-in failed (exit 1).\nerror connecting to github.com"
    })
    expect(await missing.status("example.com")).toEqual({
      host: "example.com",
      cliInstalled: false,
      supported: false,
      signedIn: false
    })
  })

  it("times out a CLI that never shows a code and replaces an older sign-in for the host", async () => {
    const env = fakeCli("gh", "exec sleep 30")
    const manager = managerWith(env, { codeWaitMs: 50, loginTimeoutMs: 300, retentionMs: 60_000 })

    const older = await manager.begin("github.com")
    const newer = await manager.begin("github.com")

    expect(older.state).toBe("starting")
    expect(manager.flow(older.id)?.state).toBe("cancelled")
    expect(await settled(manager, newer.id)).toMatchObject({
      state: "error",
      message: "Sign-in timed out. Try again."
    })
  })

  it("forgets finished sign-ins after the retention period", async () => {
    const manager = managerWith(fakeCli("gh", "exec sleep 30"), {
      codeWaitMs: 50,
      loginTimeoutMs: 60_000,
      retentionMs: 10
    })
    const flow = await manager.begin("github.com")

    expect(manager.cancel(flow.id)).toBe(true)
    expect(manager.cancel(flow.id)).toBe(true)
    expect(manager.flow(flow.id)?.state).toBe("cancelled")
    while (manager.flow(flow.id) !== undefined) {
      await new Promise((resolve) => setTimeout(resolve, 5))
    }
    expect(manager.cancel(flow.id)).toBe(false)
  })

  it("reads device codes and verification links from CLI output", () => {
    expect(parseDeviceCode("! First copy your one-time code: A6A2-6357")).toBe("A6A2-6357")
    expect(parseDeviceCode("Enter ABCD-EFGH at the page")).toBe("ABCD-EFGH")
    expect(parseDeviceCode("no code here")).toBeUndefined()
    expect(parseVerificationUrl("Open https://github.com/login/device.")).toBe(
      "https://github.com/login/device"
    )
    expect(parseVerificationUrl("nothing")).toBeUndefined()
  })
})
