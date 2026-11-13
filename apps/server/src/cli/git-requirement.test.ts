import { describe, expect, it } from "vitest"

import { authLoginCommand } from "./cloud-auth.js"
import { makeWorld, type FakeOptions } from "./support-test-support.js"
import type { ExecResult } from "./support.js"

const port = 49361
const server = `http://127.0.0.1:${port}`
const connect = `POST ${server}/v1/cloud/connect`
const installed: ExecResult = { code: 0, stdout: "", stderr: "" }

const machineWithoutGit = (platform: string, options: FakeOptions = {}) =>
  makeWorld({
    ...options,
    http: {
      [`GET ${server}/v1/cloud`]: [{ status: 200, body: {} }],
      [`GET ${server}/v1/health`]: [{ status: 200, body: { ok: true, git: "missing" } }],
      [`GET ${server}/v1/info`]: [{ status: 200, body: { platform } }]
    }
  })

describe("connecting a machine without Git", () => {
  it("stops before connecting a Mac and points to Apple's developer tools", async () => {
    const world = machineWithoutGit("darwin")

    expect(await authLoginCommand(world.deps, { port, inviteCode: "invite" })).toBe(1)

    expect(world.errors).toContain("  xcode-select --install")
    expect(world.errors.at(-1)).toBe("When Git is installed, run: codevisor auth login")
    expect(world.httpCalls(connect)).toBe(0)
  })

  it.each([
    {
      name: "the package manager it finds",
      options: { exec: { "dnf --version": installed } },
      command: "  sudo dnf install -y git"
    },
    {
      name: "no sudo when already root",
      options: { exec: { "apk --version": installed }, isRoot: true },
      command: "  apk add git"
    },
    {
      name: "no command when it knows no package manager",
      options: {},
      command: "Install it with your package manager."
    }
  ])("tells a Linux machine how to install Git: $name", async ({ options, command }) => {
    const world = machineWithoutGit("linux", options)

    expect(await authLoginCommand(world.deps, { port })).toBe(1)

    expect(world.errors).toContain(command)
    expect(world.httpCalls(connect)).toBe(0)
  })
})
