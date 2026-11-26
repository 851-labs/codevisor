import { describe, expect, it } from "vitest"

import {
  CONFIG,
  DATA_DIR,
  fakeMachine,
  type FakeMachineOptions,
  UBUNTU,
  UNIT
} from "./desktop-test-support.js"

const withoutSystemd = { files: UBUNTU, failing: ["systemctl --user show-environment"] }
const pidFile = `${DATA_DIR}/desktop.pid`
const oldUnit = {
  "/etc/systemd/system/vncserver@.service": "[Unit]\nDescription=Codevisor desktop, TigerVNC\n"
}
const listUnits = "systemctl list-units --all --plain --no-legend vncserver@*.service"
const ps = "ps -eo user=,pid=,args="

const setUpAsAProcess = async (): Promise<string> => {
  const machine = fakeMachine(withoutSystemd)
  await machine.manager.start()
  return machine.files.get(CONFIG) ?? ""
}

const userSystemctl = (commands: string[]): string[] =>
  commands.filter((line) => line.includes("systemctl --user") && !line.endsWith("show-environment"))

const oldDesktopWith = (results: NonNullable<FakeMachineOptions["results"]>) =>
  fakeMachine({
    files: { ...UBUNTU, ...oldUnit },
    folders: { "/etc/systemd/system/multi-user.target.wants": ["vncserver@1.service"] },
    results
  })

describe("an older root desktop", () => {
  it("has its running instances stopped too, enabled or not, before its unit file goes", async () => {
    const machine = oldDesktopWith({
      [listUnits]: {
        code: 0,
        output:
          "vncserver@1.service loaded active running Codevisor\nvncserver@2.service loaded active running Codevisor\n"
      }
    })
    expect((await machine.manager.status()).oldDesktop).toEqual({
      units: ["vncserver@1.service", "vncserver@2.service"]
    })
    await machine.manager.replaceOld()
    expect(
      machine.commands.filter((line) => line.startsWith("sudo -n ") && line !== "sudo -n true")
    ).toEqual([
      "sudo -n systemctl disable --now vncserver@1.service",
      "sudo -n systemctl disable --now vncserver@2.service",
      "sudo -n rm -f /etc/systemd/system/vncserver@.service",
      "sudo -n systemctl daemon-reload"
    ])
  })

  it("is reported as still running when its X server outlives the removal", async () => {
    const machine = oldDesktopWith({
      [ps]: {
        code: 0,
        output:
          "root 880 /usr/bin/Xtigervnc :1 -localhost=1\ncodevisor 990 Xvnc :1 -auth x\nroot 991 /usr/bin/Xtigervnc :7\n"
      }
    })
    await expect(machine.manager.replaceOld()).rejects.toMatchObject({
      status: 502,
      message:
        "The older desktop is still running: a root X server on :1 (pid 880). Stop it, then set the desktop up again."
    })
  })
})

describe("a desktop config Codevisor didn't write", () => {
  const theirs = JSON.stringify({ vnc: { socket: "/home/dev/desk.sock", display: 4 } })

  it("is not removed: only unshared, when that is asked for, with nothing stopped", async () => {
    const machine = fakeMachine({ files: { ...UBUNTU, [CONFIG]: theirs } })
    await expect(machine.manager.remove()).rejects.toMatchObject({
      status: 409,
      message: expect.stringContaining("Codevisor can't remove it")
    })
    expect(machine.files.get(CONFIG)).toBe(theirs)

    expect(await machine.manager.remove({ unshareUnmanaged: true })).toMatchObject({
      state: "none"
    })
    expect(machine.files.has(CONFIG)).toBe(false)
    expect(userSystemctl(machine.commands)).toEqual([])
    expect(machine.terminated).toEqual([])
  })

  it("counts as someone else's even when no desktop can be read from it", async () => {
    const unusable = JSON.stringify({ vnc: { socket: "relative.sock" } })
    const machine = fakeMachine({ files: { ...UBUNTU, [CONFIG]: unusable } })
    expect(await machine.manager.status()).toMatchObject({ state: "none", unmanaged: true })
    await expect(machine.manager.start()).rejects.toMatchObject({ status: 409 })
    expect(machine.files.get(CONFIG)).toBe(unusable)
  })
})

describe("a desktop run as a plain process whose runner was killed", () => {
  it("has its orphaned X server stopped before a new one is started on that display", async () => {
    const socket = "/home/codevisor/.codevisor/run/codevisor-desktop.sock"
    const orphaned = {
      ...withoutSystemd,
      env: {},
      files: {
        ...UBUNTU,
        [CONFIG]: await (async () => {
          const first = fakeMachine({ ...withoutSystemd, env: {} })
          await first.manager.start()
          return first.files.get(CONFIG) ?? ""
        })(),
        "/tmp/.X1-lock": "  777\n",
        "/proc/777/cmdline": `Xvnc\0:1\0-rfbunixpath\0${socket}`
      },
      alive: [777]
    }
    for (const restart of ["resume", "start"] as const) {
      const machine = fakeMachine(orphaned)
      await machine.manager[restart]()
      expect(machine.terminated).toEqual([777])
      expect(machine.spawned).toHaveLength(1)
    }
  })

  it("leaves an X server alone that belongs to a runner that is alive", async () => {
    const machine = fakeMachine({
      ...withoutSystemd,
      files: {
        ...UBUNTU,
        [CONFIG]: await setUpAsAProcess(),
        [pidFile]: "4242\n",
        "/proc/4242/cmdline": "node\0cli.js\0desktop\0run",
        "/tmp/.X1-lock": "  777\n",
        "/proc/777/cmdline": "Xvnc\0:1\0-rfbunixpath\0/run/user/1001/codevisor-desktop.sock"
      },
      alive: [4242, 777]
    })
    await machine.manager.resume()
    expect(machine.terminated).toEqual([])
  })
})

describe("a server that can't see its account's systemd by itself", () => {
  const asASystemService: FakeMachineOptions = {
    files: UBUNTU,
    env: {},
    failing: ["systemctl --user show-environment"],
    existing: ["/run/user/1001"]
  }

  it("reaches it through the account's runtime folder, so the desktop is not tied to the server", async () => {
    const machine = fakeMachine(asASystemService)
    const status = await machine.manager.start()
    expect(machine.spawned).toEqual([])
    expect(machine.files.has(UNIT)).toBe(true)
    expect(userSystemctl(machine.commands)).toEqual([
      "env XDG_RUNTIME_DIR=/run/user/1001 systemctl --user daemon-reload",
      "env XDG_RUNTIME_DIR=/run/user/1001 systemctl --user enable codevisor-desktop.service",
      "env XDG_RUNTIME_DIR=/run/user/1001 systemctl --user restart codevisor-desktop.service"
    ])
    expect(status.logHint).toBe(
      "XDG_RUNTIME_DIR=/run/user/1001 journalctl --user -u codevisor-desktop"
    )
    expect(JSON.parse(machine.files.get(CONFIG) ?? "")).toMatchObject({ service: "systemd-user" })
  })

  it("runs the desktop as a process only when the account has no systemd to reach", async () => {
    const machine = fakeMachine({ ...asASystemService, existing: [] })
    await machine.manager.start()
    expect(machine.spawned).toHaveLength(1)
    expect(machine.files.has(UNIT)).toBe(false)
  })
})

describe("a desktop set up as a process, on a server that now has systemd", () => {
  it("is started again under systemd when the server starts, and its config says so", async () => {
    const machine = fakeMachine({
      files: { ...UBUNTU, [CONFIG]: await setUpAsAProcess() },
      socketAppearsAfterPolls: Number.POSITIVE_INFINITY
    })
    await machine.manager.resume()
    expect(machine.spawned).toEqual([])
    expect(userSystemctl(machine.commands)).toContain(
      "systemctl --user restart codevisor-desktop.service"
    )
    expect(JSON.parse(machine.files.get(CONFIG) ?? "")).toMatchObject({ service: "systemd-user" })
  })

  it("stays down, and says why, when another server on the account owns the desktop unit", async () => {
    const owner = fakeMachine({ files: UBUNTU })
    await owner.manager.start()
    const theirUnit = (owner.files.get(UNIT) ?? "").replaceAll(DATA_DIR, "/home/codevisor/a/data")
    const machine = fakeMachine({
      files: { ...UBUNTU, [CONFIG]: await setUpAsAProcess(), [UNIT]: theirUnit },
      socketAppearsAfterPolls: Number.POSITIVE_INFINITY
    })

    await machine.manager.resume()
    expect(machine.files.get(UNIT)).toBe(theirUnit)
    expect(userSystemctl(machine.commands)).toEqual([])
    expect(machine.spawned).toEqual([])
    expect(JSON.parse(machine.files.get(CONFIG) ?? "")).toMatchObject({ service: "process" })
    expect(await machine.manager.status()).toMatchObject({
      state: "stopped",
      problem: expect.stringContaining("Another Codevisor server on this account")
    })
  })

  it("has the X server its killed runner left behind stopped first, so the unit can take the display", async () => {
    const machine = fakeMachine({
      files: {
        ...UBUNTU,
        [CONFIG]: await setUpAsAProcess(),
        "/tmp/.X1-lock": "  777\n",
        "/proc/777/cmdline": "Xvnc\0:1\0-rfbunixpath\0/run/user/1001/codevisor-desktop.sock"
      },
      alive: [777],
      socketAppearsAfterPolls: Number.POSITIVE_INFINITY
    })
    await machine.manager.resume()
    expect(machine.terminated).toEqual([777])
    expect(JSON.parse(machine.files.get(CONFIG) ?? "")).toMatchObject({
      vnc: { display: 1 },
      service: "systemd-user"
    })
  })

  it("is left as it is while its process still runs", async () => {
    const machine = fakeMachine({
      files: {
        ...UBUNTU,
        [CONFIG]: await setUpAsAProcess(),
        [pidFile]: "4242\n",
        "/proc/4242/cmdline": "node\0cli.js\0desktop\0run"
      },
      alive: [4242]
    })
    await machine.manager.resume()
    expect(userSystemctl(machine.commands)).toEqual([])
    expect(machine.terminated).toEqual([])
  })
})

describe("a desktop whose session keeps dying", () => {
  it("is not called ready, and not called running, while only its X server's socket is there", async () => {
    const machine = fakeMachine({ files: UBUNTU, sessionNeverSettles: true })
    await expect(machine.manager.start()).rejects.toMatchObject({ status: 500 })
    expect(await machine.manager.status()).toMatchObject({
      state: "stopped",
      problem: "the desktop's session isn't up",
      keepsRunning: false
    })
  })
})
