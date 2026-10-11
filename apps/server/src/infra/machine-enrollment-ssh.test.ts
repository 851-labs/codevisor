import childProcess from "node:child_process"
import { chmodSync, existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs"
import { syncBuiltinESMExports } from "node:module"
import { tmpdir } from "node:os"
import { join } from "node:path"

import type { CloudMachinePresence, MachineSummary } from "@codevisor/api"
import { afterEach, describe, expect, it, vi } from "vitest"

import { HttpFailure } from "../server-context.js"
import { makeMachineEnrollment, type MachineEnrollmentCloud } from "./machine-enrollment.js"
import { makeMachineLink } from "./machine-link.js"

const CODE = "cvi1.aHR0cHM6Ly9jbG91ZC5leGFtcGxl.secret-secret-secret-secret"
const SELF_DEVICE = "device-self"

const presence = (
  deviceId: string,
  name: string,
  extra: Partial<CloudMachinePresence> = {}
): CloudMachinePresence => ({
  deviceId,
  name,
  publicKey: "pk",
  online: true,
  lastSeenAt: "2100-01-01T00:00:00.000Z",
  ...extra
})

/// Observes the real owned SSH child without replacing its process behavior.
class SshCancellation {
  readonly caller = new AbortController()
  readonly ready = Promise.withResolvers<void>()
  private closed: Promise<void> | undefined
  #restore: () => void

  constructor(command: string) {
    const actualSpawn = childProcess.spawn
    let output = ""
    const observe = vi.spyOn(childProcess, "spawn").mockImplementation((...args) => {
      const child = actualSpawn(...args)
      if (args[0] === command) {
        this.closed = new Promise((resolve) => child.once("close", () => resolve()))
        child.stdout?.on("data", (chunk: Buffer) => {
          output += chunk.toString("utf8")
          if (output.includes("codevisor-ssh-ready\n")) this.ready.resolve()
        })
        child.once("close", () => this.ready.reject(new Error("ssh closed before readiness")))
      }
      return child
    })
    this.#restore = () => {
      observe.mockRestore()
      syncBuiltinESMExports()
    }
    try {
      syncBuiltinESMExports()
    } catch (error) {
      this.#restore()
      throw error
    }
  }

  async settle(pending: Promise<MachineSummary> | undefined): Promise<void> {
    this.caller.abort()
    try {
      await pending?.catch(() => undefined)
      await this.closed
    } finally {
      this.#restore()
    }
  }
}

describe("the real ssh runner", () => {
  const directories: string[] = []
  afterEach(() => {
    for (const directory of directories.splice(0))
      rmSync(directory, { recursive: true, force: true })
  })

  /// A stand-in `ssh` that records its stdin and behaves per `body`.
  const fakeSsh = (body: string): { command: string; stdinPath: string } => {
    const directory = mkdtempSync(join(tmpdir(), "codevisor-fake-ssh-"))
    directories.push(directory)
    const command = join(directory, "ssh")
    const stdinPath = join(directory, "stdin")
    writeFileSync(command, `#!/bin/sh\ncat > '${stdinPath}'\n${body}\n`)
    chmodSync(command, 0o755)
    return { command, stdinPath }
  }

  const account = (joinedOnce: () => boolean): MachineEnrollmentCloud => ({
    deviceId: () => SELF_DEVICE,
    machines: () => [
      presence(SELF_DEVICE, "mac-studio", { serverId: "machine-self" }),
      ...(joinedOnce()
        ? [
            presence("device-new", "hetzner-1", {
              serverId: "machine-new",
              addedBy: { deviceId: SELF_DEVICE, name: "mac-studio" }
            })
          ]
        : [])
    ],
    invite: async () => ({ code: CODE, expiresAt: "2100-01-01T00:10:00Z" }),
    removePeer: async () => undefined
  })

  const linkFor = (cloud: MachineEnrollmentCloud) =>
    makeMachineLink({
      self: { id: "machine-self", name: () => "mac-studio", os: "darwin" },
      cloud: { ...cloud, request: () => Promise.reject(new Error("unused")) },
      now: Date.now
    })

  it("runs ssh with the script on stdin and the default installer", async () => {
    const ssh = fakeSsh('echo "✓ Connected as hetzner-1."')
    // The new machine is on the account once the host has run the script.
    const cloud = account(() => existsSync(ssh.stdinPath))
    const enrollment = makeMachineEnrollment({
      cloud,
      link: linkFor(cloud),
      sshCommand: ssh.command
    })
    expect(await enrollment.add({ ssh: "box" })).toMatchObject({
      name: "hetzner-1",
      addedBy: "mac-studio"
    })
    const script = readFileSync(ssh.stdinPath, "utf8")
    expect(script).toContain(CODE)
    expect(script).toContain("https://www.codevisor.dev/install.sh")
  })

  it("polls on the real clock until the new machine comes online", async () => {
    const ssh = fakeSsh("true")
    let polls = 0
    const cloud = account(() => existsSync(ssh.stdinPath))
    const machines = cloud.machines
    const enrollment = makeMachineEnrollment({
      cloud: {
        ...cloud,
        // Offline on the first poll after the install, online on the next.
        machines: () =>
          (machines() ?? []).map((machine) =>
            machine.deviceId === "device-new" ? { ...machine, online: ++polls > 1 } : machine
          )
      },
      link: linkFor(cloud),
      sshCommand: ssh.command
    })
    expect((await enrollment.add({ ssh: "box" })).online).toBe(true)
    expect(polls).toBe(2)
  })

  it("keeps only the tail of a long run's output", async () => {
    const ssh = fakeSsh(
      'i=0; while [ $i -lt 4000 ]; do echo "line $i of noisy install output"; i=$((i+1)); done; exit 7'
    )
    const cloud = account(() => false)
    const enrollment = makeMachineEnrollment({
      cloud,
      link: linkFor(cloud),
      sshCommand: ssh.command
    })
    const message = await enrollment.add({ ssh: "box" }).then(
      () => "",
      (error: HttpFailure) => error.message
    )
    expect(message).toContain("failed (exit 7)")
    expect(message).toContain("line 3999 of noisy install output")
    expect(message).not.toContain("line 3900 ")
  })

  it("stops the run when the caller cancels", async () => {
    const ssh = fakeSsh("printf 'codevisor-ssh-ready\\n'\nexec sleep 30")
    const cloud = account(() => false)
    const enrollment = makeMachineEnrollment({
      cloud,
      link: linkFor(cloud),
      sshCommand: ssh.command
    })
    const cancellation = new SshCancellation(ssh.command)
    let pending: Promise<MachineSummary> | undefined
    try {
      pending = enrollment.add({ ssh: "box" }, cancellation.caller.signal)
      void pending.then(
        () => cancellation.ready.reject(new Error("ssh completed before readiness")),
        cancellation.ready.reject
      )
      await cancellation.ready.promise
      cancellation.caller.abort()
      await expect(pending).rejects.toMatchObject({
        message: expect.stringContaining("timed out or was cancelled")
      })
    } finally {
      await cancellation.settle(pending)
    }
  })

  it("says so when ssh can't run here", async () => {
    const cloud = account(() => false)
    const enrollment = makeMachineEnrollment({
      cloud,
      link: linkFor(cloud),
      sshCommand: join(tmpdir(), "codevisor-no-such-ssh")
    })
    await expect(enrollment.add({ ssh: "box" })).rejects.toMatchObject({
      status: 501,
      message: expect.stringContaining("Couldn't run ssh")
    })
  })
})
