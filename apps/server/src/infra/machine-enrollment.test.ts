import { spawnSync } from "node:child_process"
import { chmodSync, existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"

import type { CloudMachinePresence, MachineSummary } from "@codevisor/api"
import { CloudApiError } from "@codevisor/cloud-client"
import { afterEach, describe, expect, it } from "vitest"

import { HttpFailure } from "../server-context.js"
import {
  makeMachineEnrollment,
  remoteInstallScript,
  shellQuote,
  sshArgs,
  type MachineEnrollmentCloud,
  type SshRun
} from "./machine-enrollment.js"
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

/// A fake account: `onSsh` decides what the host does with the script.
const harness = (options: {
  onSsh?: (script: string, machines: CloudMachinePresence[]) => SshRun
  invite?: () => Promise<{ code: string; expiresAt: string }>
  /// Runs on each poll wait, with the account's machines.
  onSleep?: (machines: CloudMachinePresence[]) => void
  cloud?: Partial<MachineEnrollmentCloud>
  /// What machines.list() answers, when it shouldn't follow the cloud.
  list?: () => Promise<ReadonlyArray<MachineSummary>>
}) => {
  const machines: CloudMachinePresence[] = [
    presence(SELF_DEVICE, "mac-studio", { serverId: "machine-self" })
  ]
  const removed: string[] = []
  const sshCalls: { args: ReadonlyArray<string>; stdin: string }[] = []
  let clock = 0
  const cloud: MachineEnrollmentCloud = {
    deviceId: () => SELF_DEVICE,
    machines: () => machines,
    invite: options.invite ?? (async () => ({ code: CODE, expiresAt: "2100-01-01T00:10:00Z" })),
    removePeer: async (deviceId) => {
      if (!machines.some((machine) => machine.deviceId === deviceId)) {
        throw new CloudApiError("unknown machine", 404)
      }
      removed.push(deviceId)
      machines.splice(
        machines.findIndex((machine) => machine.deviceId === deviceId),
        1
      )
    },
    ...options.cloud
  }
  const link = makeMachineLink({
    self: { id: "machine-self", name: () => "mac-studio", os: "darwin" },
    cloud: {
      deviceId: cloud.deviceId,
      machines: cloud.machines,
      request: () => Promise.reject(new Error("unused"))
    },
    now: () => clock
  })
  const enrollment = makeMachineEnrollment({
    cloud,
    link: options.list === undefined ? link : { ...link, list: options.list },
    installUrl: "https://example.test/install.sh",
    runSsh: async (args, stdin) => {
      sshCalls.push({ args, stdin })
      return options.onSsh?.(stdin, machines) ?? { exitCode: 0, output: "" }
    },
    sleep: async (ms) => {
      clock += ms
      options.onSleep?.(machines)
    },
    now: () => clock
  })
  return { enrollment, machines, removed, sshCalls }
}

const joinAs = (name: string, extra: Partial<CloudMachinePresence> = {}) => {
  return (_script: string, machines: CloudMachinePresence[]): SshRun => {
    machines.push(
      presence("device-new", name, {
        serverId: "machine-new",
        addedBy: { deviceId: SELF_DEVICE, name: "mac-studio" },
        ...extra
      })
    )
    return { exitCode: 0, output: `✓ Connected as ${name}.` }
  }
}

describe("remoteInstallScript", () => {
  it("runs as a POSIX script that hands the installer the invite and name", () => {
    const script = remoteInstallScript({
      inviteCode: CODE,
      installUrl: "https://example.test/install.sh",
      name: "it's-a-box"
    })
    // Replace the download with a probe that prints what the installer sees.
    const probe = script.replace(
      /url=.*\n[\s\S]*$/,
      'printf "%s|%s|%s" "$CODEVISOR_INVITE" "$CODEVISOR_NO_SETUP" "$CODEVISOR_MACHINE_NAME"\n'
    )
    const result = spawnSync("sh", ["-s"], { input: probe, encoding: "utf8" })
    expect(result.stdout).toBe(`${CODE}|1|it's-a-box`)
  })

  it("quotes anything safely", () => {
    const tricky = `a'b"c$(touch /tmp/x)`
    const result = spawnSync("sh", ["-c", `printf %s ${shellQuote(tricky)}`], { encoding: "utf8" })
    expect(result.stdout).toBe(tricky)
  })
})

describe("sshArgs", () => {
  it("never allocates a terminal, never prompts, and ends options before the host", () => {
    const args = sshArgs("root@203.0.113.7", 2222)
    expect(args).not.toContain("-t")
    expect(args).toContain("BatchMode=yes")
    expect(args.slice(-3)).toEqual(["--", "root@203.0.113.7", "sh -s"])
    expect(args.join(" ")).toContain("-p 2222")
  })
})

describe("machine enrollment", () => {
  it("installs over SSH with the invite on stdin and returns the joined machine", async () => {
    const { enrollment, sshCalls } = harness({ onSsh: joinAs("hetzner-1") })
    const machine = await enrollment.add({ ssh: "root@203.0.113.7", name: "hetzner-1" })
    expect(machine).toMatchObject({
      id: "machine-new",
      name: "hetzner-1",
      online: true,
      isCurrent: false,
      addedBy: "mac-studio"
    })
    expect(sshCalls).toHaveLength(1)
    expect(sshCalls[0]!.args.join(" ")).not.toContain(CODE)
    expect(sshCalls[0]!.stdin).toContain(CODE)
  })

  it("waits for the joined machine to come online", async () => {
    let waits = 0
    const { enrollment } = harness({
      onSsh: joinAs("hetzner-1", { online: false }),
      onSleep: (machines) => {
        waits += 1
        const index = machines.findIndex((machine) => machine.deviceId === "device-new")
        if (waits === 3) machines[index] = { ...machines[index]!, online: true }
      }
    })
    expect((await enrollment.add({ ssh: "box" })).online).toBe(true)
    expect(waits).toBe(3)
  })

  it("rejects destinations that could smuggle ssh options", async () => {
    const { enrollment, sshCalls } = harness({})
    for (const ssh of ["-oProxyCommand=evil", "host name", ""]) {
      await expect(enrollment.add({ ssh })).rejects.toMatchObject({ status: 400 })
    }
    expect(sshCalls).toHaveLength(0)
  })

  it("reports SSH and install failures without leaking the invite", async () => {
    const unreachable = harness({
      onSsh: () => ({ exitCode: 255, output: `ssh: connect refused ${CODE}` })
    })
    const failure = await unreachable.enrollment.add({ ssh: "box" }).catch((error) => error)
    expect(failure).toBeInstanceOf(HttpFailure)
    expect(failure.message).toContain("could not connect over SSH")
    expect(failure.message).not.toContain(CODE)

    const quiet = harness({ onSsh: () => ({ exitCode: 0, output: "installed" }) })
    await expect(quiet.enrollment.add({ ssh: "box" })).rejects.toMatchObject({ status: 504 })

    const taken = harness({
      onSsh: () => ({ exitCode: 0, output: "This machine is already connected to Cloud." })
    })
    await expect(taken.enrollment.add({ ssh: "box" })).rejects.toMatchObject({ status: 409 })
  })

  it("passes the cloud's refusal through without touching the host", async () => {
    const { enrollment, sshCalls } = harness({
      invite: () => Promise.reject(new CloudApiError("invalid machine credential", 401))
    })
    await expect(enrollment.add({ ssh: "box" })).rejects.toMatchObject({
      status: 502,
      message: "invalid machine credential"
    })
    expect(sshCalls).toHaveLength(0)
  })

  it("removes another machine by name or id, never itself", async () => {
    const { enrollment, machines, removed } = harness({})
    machines.push(presence("device-a", "hetzner-1", { serverId: "machine-a" }))
    machines.push(presence("device-b", "hetzner-2", { serverId: "machine-b" }))
    expect((await enrollment.remove("HETZNER-1")).map((machine) => machine.name)).toEqual([
      "mac-studio",
      "hetzner-2"
    ])
    await enrollment.remove("machine-b")
    expect(removed).toEqual(["device-a", "device-b"])
    await expect(enrollment.remove("mac-studio")).rejects.toMatchObject({ status: 400 })
    await expect(enrollment.remove("nope")).rejects.toMatchObject({ status: 404 })
  })
})

describe("machine enrollment edge cases", () => {
  it("validates the name and SSH port before creating an invite", async () => {
    const { enrollment, sshCalls } = harness({})
    for (const request of [
      { ssh: "box", name: " " },
      { ssh: "box", name: "x".repeat(121) },
      { ssh: "box", sshPort: 0 },
      { ssh: "box", sshPort: 65_536 },
      { ssh: "box", sshPort: 22.5 }
    ]) {
      await expect(enrollment.add(request)).rejects.toMatchObject({ status: 400 })
    }
    expect(sshCalls).toHaveLength(0)
  })

  it("reports a cancelled run and any other failed exit", async () => {
    const cancelled = harness({ onSsh: () => ({ exitCode: null, output: "partial" }) })
    await expect(cancelled.enrollment.add({ ssh: "box" })).rejects.toMatchObject({
      status: 502,
      message: expect.stringContaining("timed out or was cancelled")
    })
    const failed = harness({ onSsh: () => ({ exitCode: 1, output: "curl: not found" }) })
    await expect(failed.enrollment.add({ ssh: "box" })).rejects.toMatchObject({
      message: expect.stringContaining("failed (exit 1)")
    })
  })

  it("maps failures creating the invite to clear statuses", async () => {
    const cases: Array<[unknown, number, string]> = [
      [new HttpFailure(418, "as is"), 418, "as is"],
      [
        new Error("This machine is not connected to a Codevisor Cloud account"),
        409,
        "not connected"
      ],
      ["socket hang up", 502, "socket hang up"]
    ]
    for (const [cause, status, message] of cases) {
      const { enrollment } = harness({ invite: () => Promise.reject(cause) })
      await expect(enrollment.invite()).rejects.toMatchObject({
        status,
        message: expect.stringContaining(message)
      })
    }
  })

  it("works without a machine list yet, and describes a joined machine the list doesn't show", async () => {
    let listed: CloudMachinePresence[] | undefined
    const joined = presence("device-new", "hetzner-1", {
      os: "linux",
      addedBy: { deviceId: SELF_DEVICE, name: "mac-studio" }
    })
    const { enrollment } = harness({
      cloud: { machines: () => listed },
      onSsh: () => {
        listed = [joined]
        return { exitCode: 0, output: "" }
      },
      list: async () => []
    })
    expect(await enrollment.add({ ssh: "box" })).toEqual({
      id: "cloud:device-new",
      name: "hetzner-1",
      os: "linux",
      online: true,
      lastSeen: joined.lastSeenAt,
      isCurrent: false,
      addedBy: "mac-studio"
    })

    const bare = presence("device-new", "hetzner-1")
    listed = undefined
    const plain = harness({
      cloud: {
        machines: () => listed,
        // The cloud's list names no inviter; the poll still matches our own device.
        deviceId: () => undefined
      },
      onSsh: () => {
        listed = [bare]
        return { exitCode: 0, output: "" }
      },
      list: async () => []
    })
    expect(await plain.enrollment.add({ ssh: "box" })).toEqual({
      id: "cloud:device-new",
      name: "hetzner-1",
      online: true,
      lastSeen: joined.lastSeenAt,
      isCurrent: false
    })
  })

  it("stops waiting for the machine when the caller cancels", async () => {
    const caller = new AbortController()
    const { enrollment } = harness({
      onSsh: joinAs("hetzner-1", { online: false }),
      onSleep: () => caller.abort()
    })
    // Cancelled mid-wait, it answers with what it saw (still offline).
    expect((await enrollment.add({ ssh: "box" }, caller.signal)).online).toBe(false)
  })

  it("treats a machine the cloud no longer has as unknown", async () => {
    const { enrollment, machines } = harness({
      cloud: { removePeer: () => Promise.reject(new CloudApiError("unknown machine", 404)) }
    })
    machines.push(presence("device-a", "hetzner-1", { serverId: "machine-a" }))
    await expect(enrollment.remove("hetzner-1")).rejects.toMatchObject({ status: 404 })
  })

  it("gives up waiting when the account's machine list never arrives", async () => {
    const { enrollment } = harness({ cloud: { machines: () => undefined } })
    await expect(enrollment.add({ ssh: "box" })).rejects.toMatchObject({ status: 504 })
  })

  it("reports a failed removal other than an unknown machine", async () => {
    const { enrollment, machines } = harness({
      cloud: { removePeer: () => Promise.reject(new CloudApiError("cloud down", 503)) }
    })
    machines.push(presence("device-a", "hetzner-1", { serverId: "machine-a" }))
    await expect(enrollment.remove("hetzner-1")).rejects.toMatchObject({
      status: 502,
      message: "cloud down"
    })
  })
})

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
    const ssh = fakeSsh("sleep 30")
    const cloud = account(() => false)
    const enrollment = makeMachineEnrollment({
      cloud,
      link: linkFor(cloud),
      sshCommand: ssh.command
    })
    const caller = new AbortController()
    const pending = enrollment.add({ ssh: "box" }, caller.signal)
    setTimeout(() => caller.abort(), 50)
    await expect(pending).rejects.toMatchObject({
      message: expect.stringContaining("timed out or was cancelled")
    })
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
