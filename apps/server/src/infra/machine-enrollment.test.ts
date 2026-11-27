import { spawnSync } from "node:child_process"

import type { CloudMachinePresence, MachineSummary } from "@codevisor/api"
import { CloudApiError } from "@codevisor/cloud-client"
import { describe, expect, it } from "vitest"

import { HttpFailure } from "../server-context.js"
import {
  makeMachineEnrollment,
  remoteInstallScript,
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

const harness = (options: {
  onSsh?: (script: string, machines: CloudMachinePresence[]) => SshRun
  invite?: () => Promise<{ code: string; expiresAt: string }>
  onSleep?: (machines: CloudMachinePresence[]) => void
  cloud?: Partial<MachineEnrollmentCloud>
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

const desktopAskedBy = (script: string): string =>
  spawnSync("sh", ["-s"], {
    input: script.replace(/url=.*\n[\s\S]*$/, 'printf "%s" "${CODEVISOR_DESKTOP:-unset}"\n'),
    encoding: "utf8",
    env: { PATH: process.env["PATH"] }
  }).stdout

describe("remoteInstallScript", () => {
  it("runs as a POSIX script that hands the installer the invite and name", () => {
    const script = remoteInstallScript({
      inviteCode: CODE,
      installUrl: "https://example.test/install.sh",
      name: `a'b"c$(touch /tmp/x)`
    })
    const probe = script.replace(
      /url=.*\n[\s\S]*$/,
      'printf "%s|%s|%s" "$CODEVISOR_INVITE" "$CODEVISOR_NO_SETUP" "$CODEVISOR_MACHINE_NAME"\n'
    )
    const result = spawnSync("sh", ["-s"], { input: probe, encoding: "utf8" })
    expect(result.stdout).toBe(`${CODE}|1|a'b"c$(touch /tmp/x)`)
  })

  it("asks the installer for a desktop only when one was asked for", () => {
    const base = { inviteCode: CODE, installUrl: "https://example.test/install.sh" }
    expect(desktopAskedBy(remoteInstallScript({ ...base, desktop: true }))).toBe("1")
    expect(desktopAskedBy(remoteInstallScript(base))).toBe("unset")
    expect(desktopAskedBy(remoteInstallScript({ ...base, desktop: false }))).toBe("unset")
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

const readyInstall = (script: string, machines: CloudMachinePresence[]): SshRun => ({
  ...joinAs("hetzner-1")(script, machines),
  output:
    "==> Setting up a desktop\n==> The desktop is ready. Open it from this machine in Codevisor."
})

const slowInstall = (script: string, machines: CloudMachinePresence[]): SshRun => ({
  ...joinAs("hetzner-1")(script, machines),
  exitCode: null,
  output:
    "\u001B[1;32m==>\u001B[0m Setting up a desktop\n==> Installing Xfce and TigerVNC with apt (about 640 MB)"
})

const unreachableHost = (): SshRun => ({
  exitCode: 255,
  output: "ssh: connect to host box port 22: refused"
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

  it("has the installer set up a desktop on the new machine when asked, and not otherwise", async () => {
    const withOne = harness({ onSsh: joinAs("hetzner-1") })
    expect(await withOne.enrollment.add({ ssh: "root@203.0.113.7", desktop: true })).toMatchObject({
      desktop: "not-set-up"
    })
    expect(desktopAskedBy(withOne.sshCalls[0]!.stdin)).toBe("1")

    const without = harness({ onSsh: joinAs("hetzner-2") })
    expect(await without.enrollment.add({ ssh: "root@203.0.113.8" })).not.toHaveProperty("desktop")
    expect(desktopAskedBy(without.sshCalls[0]!.stdin)).toBe("unset")
  })

  it("reads from the installer's output whether the desktop came up", async () => {
    const { enrollment } = harness({ onSsh: readyInstall })
    expect(await enrollment.add({ ssh: "root@203.0.113.7", desktop: true })).toMatchObject({
      name: "hetzner-1",
      desktop: "ready"
    })
  })

  it("counts a machine that joined before its desktop setup ran out of time as added, without a desktop", async () => {
    const { enrollment } = harness({ onSsh: slowInstall })
    expect(await enrollment.add({ ssh: "root@203.0.113.7", desktop: true })).toMatchObject({
      name: "hetzner-1",
      desktop: "not-set-up"
    })

    const plain = harness({ onSsh: slowInstall })
    await expect(plain.enrollment.add({ ssh: "root@203.0.113.7" })).rejects.toMatchObject({
      status: 502
    })
  })

  it("reports a failure before the desktop step at once, without waiting for a join", async () => {
    let sleeps = 0
    const { enrollment } = harness({
      onSsh: unreachableHost,
      onSleep: () => {
        sleeps += 1
      }
    })
    await expect(enrollment.add({ ssh: "box", desktop: true })).rejects.toMatchObject({
      status: 502
    })
    expect(sleeps).toBe(0)
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
