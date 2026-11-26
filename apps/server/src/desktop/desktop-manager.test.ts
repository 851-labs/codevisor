import { describe, expect, it } from "vitest"

import {
  APT_UPDATE_LOOP,
  CHANGED,
  CONFIG,
  DATA_DIR,
  fakeMachine,
  settled,
  UBUNTU,
  UNIT
} from "./desktop-test-support.js"

const aptUpdate = `env DEBIAN_FRONTEND=noninteractive sh -c ${APT_UPDATE_LOOP}`
const aptInstall =
  "env DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=600 install -y -q --no-install-recommends tigervnc-standalone-server tigervnc-common xfce4 xfce4-terminal dbus-x11 xclip python3 fonts-dejavu-core adwaita-icon-theme"
const bare = ["apt-get", "sudo"]
const oldUnit = {
  "/etc/systemd/system/vncserver@.service":
    "[Unit]\nDescription=Codevisor desktop, TigerVNC display :%i (localhost only, no VNC password)\n"
}
const oldEnabled = {
  "/etc/systemd/system/multi-user.target.wants": ["vncserver@1.service", "ssh.service"]
}
const linger = "loginctl show-user codevisor --property=Linger --value"

describe("what a Linux machine needs before it has a desktop", () => {
  it("lists what is missing and which package manager installs it on a fresh Ubuntu server", async () => {
    const machine = fakeMachine({ programs: bare, files: UBUNTU })
    expect(await machine.manager.status()).toMatchObject({
      state: "none",
      account: "codevisor",
      system: "Ubuntu 24.04.5 LTS",
      missing: ["Xvnc", "startxfce4", "xfconf-query", "dbus-run-session", "xclip", "python3"],
      packageManager: "apt",
      sudo: "passwordless"
    })
  })

  it("names no package manager on a system whose package manager it doesn't know", async () => {
    const fedora = { "/etc/os-release": 'PRETTY_NAME="Fedora Linux 45"\nID=fedora\n' }
    const status = await fakeMachine({ programs: ["sudo"], files: fedora }).manager.status()
    expect(status.system).toBe("Fedora Linux 45")
    expect(status.missing).toHaveLength(6)
    expect(status).not.toHaveProperty("packageManager")
  })

  it.each([
    { name: "passwordless sudo", failing: [], programs: bare, uid: 1001, sudo: "passwordless" },
    {
      name: "sudo that asks",
      failing: ["sudo -n true"],
      programs: bare,
      uid: 1001,
      sudo: "password"
    },
    { name: "no sudo", failing: ["sudo -n true"], programs: ["apt-get"], uid: 1001, sudo: "none" },
    {
      name: "a server run by root",
      failing: ["sudo"],
      programs: ["apt-get"],
      uid: 0,
      sudo: "passwordless"
    }
  ])("tells $name apart", async ({ failing, programs, uid, sudo }) => {
    const machine = fakeMachine({ programs, files: UBUNTU, failing, uid })
    expect((await machine.manager.status()).sudo).toBe(sudo)
  })

  it("doesn't try sudo when nothing needs root, so a set-up machine's auth log stays quiet", async () => {
    const machine = fakeMachine({ files: UBUNTU })
    await machine.manager.start()
    await machine.manager.status()
    expect(await machine.manager.status()).not.toHaveProperty("sudo")
    expect(machine.commands.filter((line) => line.startsWith("sudo"))).toEqual([])
  })

  it("says whether the desktop will start at boot, and how to make it", async () => {
    const lingering = fakeMachine({ results: { [linger]: { code: 0, output: "yes\n" } } })
    expect(await lingering.manager.status()).toMatchObject({ startsAtBoot: true })
    expect(await lingering.manager.status()).not.toHaveProperty("startAtBootHint")

    const loggedInOnly = fakeMachine({ results: { [linger]: { code: 0, output: "no\n" } } })
    expect(await loggedInOnly.manager.status()).toMatchObject({
      startsAtBoot: false,
      startAtBootHint: "sudo loginctl enable-linger codevisor",
      logHint: "journalctl --user -u codevisor-desktop"
    })
  })
})

describe("installing the desktop's packages", () => {
  it("runs apt through sudo without a prompt when the server's account may", async () => {
    const machine = fakeMachine({ programs: bare, files: UBUNTU })
    await machine.manager.installPackages()
    expect(await settled(machine.manager)).not.toHaveProperty("failure")
    expect(machine.commands).toContain(`sudo -n ${aptUpdate}`)
    expect(machine.commands).toContain(`sudo -n ${aptInstall}`)
  })

  it("runs apt directly when the server is root", async () => {
    const machine = fakeMachine({ programs: ["apt-get"], files: UBUNTU, uid: 0 })
    await machine.manager.installPackages()
    await settled(machine.manager)
    expect(machine.commands).toContain(aptInstall)
    expect(machine.commands.filter((line) => line.startsWith("sudo"))).toEqual([])
  })

  it("refuses when sudo would ask for a password, and installs nothing", async () => {
    const machine = fakeMachine({ programs: bare, files: UBUNTU, failing: ["sudo -n true"] })
    await expect(machine.manager.installPackages()).rejects.toMatchObject({
      status: 403,
      message: "Installing packages needs an administrator on this machine"
    })
    expect(machine.commands.filter((line) => line.includes("apt-get"))).toEqual([])
  })

  it("reports the package manager's last lines when the install fails", async () => {
    const machine = fakeMachine({
      programs: bare,
      files: UBUNTU,
      results: {
        [`sudo -n ${aptInstall}`]: {
          code: 100,
          output: "Reading lists\nE: Unable to locate package xfce4\n"
        }
      }
    })
    await machine.manager.installPackages()
    expect(await settled(machine.manager)).toMatchObject({
      failure: "Installing packages failed:\nReading lists\nE: Unable to locate package xfce4"
    })
  })

  it("stops reporting a failed install once the programs are there or something else was done since", async () => {
    const failing = {
      [`sudo -n ${aptInstall}`]: { code: 100, output: "E: Unable to locate package xfce4\n" }
    }
    const fixedByHand = fakeMachine({ files: UBUNTU, results: failing })
    await fixedByHand.manager.installPackages()
    expect(await settled(fixedByHand.manager)).not.toHaveProperty("failure")

    const stillMissing = fakeMachine({ programs: bare, files: UBUNTU, results: failing })
    await stillMissing.manager.installPackages()
    expect(await settled(stillMissing.manager)).toHaveProperty("failure")
    expect(await stillMissing.manager.replaceOld()).not.toHaveProperty("failure")
  })

  it("answers at once while a long install runs, runs only one, and holds other changes back until it is done", async () => {
    const apt = Promise.withResolvers<void>()
    const machine = fakeMachine({
      files: UBUNTU,
      holds: { prefix: `sudo -n ${aptInstall}`, until: apt.promise }
    })
    expect(await machine.manager.installPackages()).toMatchObject({ busy: "Installing packages" })
    expect(await machine.manager.installPackages()).toMatchObject({ busy: "Installing packages" })
    await machine.manager.status()
    await machine.manager.status()
    expect(machine.commands.filter((line) => line === "sudo -n true")).toHaveLength(1)
    await expect(machine.manager.start()).rejects.toMatchObject({
      status: 409,
      message: "Installing packages is still going on. Try again when it is done."
    })

    apt.resolve()
    expect(await settled(machine.manager)).not.toHaveProperty("busy")
    expect(machine.commands.filter((line) => line === `sudo -n ${aptInstall}`)).toHaveLength(1)
    expect(await machine.manager.start()).toMatchObject({ state: "running" })
  })
})

describe("an older desktop that runs as root", () => {
  it("is found by the unit the old script wrote, and reported without any command to run", async () => {
    const machine = fakeMachine({ files: { ...UBUNTU, ...oldUnit }, folders: oldEnabled })
    expect((await machine.manager.status()).oldDesktop).toEqual({ units: ["vncserver@1.service"] })
  })

  it("is not what someone else's VNC unit is taken for", async () => {
    const theirs = {
      "/etc/systemd/system/vncserver@.service": "[Unit]\nDescription=Remote desktop\n"
    }
    const machine = fakeMachine({ files: { ...UBUNTU, ...theirs }, folders: oldEnabled })
    expect(await machine.manager.status()).not.toHaveProperty("oldDesktop")
  })

  it("is stopped and removed through sudo, in order", async () => {
    const machine = fakeMachine({ files: { ...UBUNTU, ...oldUnit }, folders: oldEnabled })
    await machine.manager.replaceOld()
    expect(
      machine.commands.filter((line) => line.startsWith("sudo -n ") && line !== "sudo -n true")
    ).toEqual([
      "sudo -n systemctl disable --now vncserver@1.service",
      "sudo -n rm -f /etc/systemd/system/vncserver@.service",
      "sudo -n systemctl daemon-reload"
    ])
  })
})

describe("removing the desktop", () => {
  it("withdraws the desktop from viewers first, then stops the boot service and removes it", async () => {
    const machine = fakeMachine({ files: UBUNTU })
    await machine.manager.start()
    machine.commands.length = 0

    expect(await machine.manager.remove()).toMatchObject({ state: "none" })
    expect(
      machine.commands.filter(
        (line) =>
          line === CHANGED ||
          (line.startsWith("systemctl --user") && !line.endsWith("show-environment"))
      )
    ).toEqual([
      CHANGED,
      "systemctl --user disable --now codevisor-desktop.service",
      "systemctl --user daemon-reload",
      "systemctl --user reset-failed codevisor-desktop.service"
    ])
    expect(machine.files.has(CONFIG)).toBe(false)
    expect(machine.files.has(UNIT)).toBe(false)
  })

  it("stops a desktop that runs as a plain process", async () => {
    const machine = fakeMachine({ files: UBUNTU, failing: ["systemctl --user show-environment"] })
    await machine.manager.start()
    await machine.manager.remove()
    expect(machine.terminated).toEqual([4242])
    expect(machine.files.has(`${DATA_DIR}/desktop.pid`)).toBe(false)
  })
})

describe("a server that boots where there is no systemd", () => {
  const withoutSystemd = { files: UBUNTU, failing: ["systemctl --user show-environment"] }
  const pidFile = `${DATA_DIR}/desktop.pid`
  const setUpEarlier = async () => (await startedMachine()).files.get(CONFIG) ?? ""
  const startedMachine = async () => {
    const machine = fakeMachine(withoutSystemd)
    await machine.manager.start()
    return machine
  }

  it("starts the desktop it had set up, even when the old socket file is still there", async () => {
    const rebooted = fakeMachine({
      ...withoutSystemd,
      files: { ...UBUNTU, [CONFIG]: await setUpEarlier(), [pidFile]: "4242\n" }
    })
    expect(await rebooted.manager.status()).toMatchObject({
      state: "stopped",
      problem: "the desktop's process isn't running"
    })
    await rebooted.manager.resume()
    expect(rebooted.spawned).toHaveLength(1)
  })

  it("leaves a desktop alone whose process is still running", async () => {
    const stillUp = fakeMachine({
      ...withoutSystemd,
      files: {
        ...UBUNTU,
        [CONFIG]: await setUpEarlier(),
        [pidFile]: "4242\n",
        "/proc/4242/cmdline": "node\0/opt/codevisor/cli.js\0desktop\0run"
      },
      alive: [4242]
    })
    await stillUp.manager.resume()
    expect(stillUp.spawned).toEqual([])
    expect(await stillUp.manager.status()).toMatchObject({ state: "running" })
  })

  it("doesn't take another process that got the old process's number for the desktop", async () => {
    const reused = fakeMachine({
      ...withoutSystemd,
      files: {
        ...UBUNTU,
        [CONFIG]: await setUpEarlier(),
        [pidFile]: "4242\n",
        "/proc/4242/cmdline": "node\0/opt/codevisor/main.js\0serve"
      },
      alive: [4242]
    })
    await reused.manager.resume()
    expect(reused.spawned).toHaveLength(1)

    const removed = fakeMachine({
      ...withoutSystemd,
      files: {
        ...UBUNTU,
        [pidFile]: "4242\n",
        "/proc/4242/cmdline": "node\0/opt/codevisor/main.js\0serve"
      },
      alive: [4242]
    })
    await removed.manager.remove()
    expect(removed.terminated).toEqual([])
  })

  it("doesn't start a runner for a config it can't share, whatever service the config names", async () => {
    const outdated = JSON.stringify({ vnc: { port: 5901 }, service: "process" })
    const machine = fakeMachine({ ...withoutSystemd, files: { ...UBUNTU, [CONFIG]: outdated } })
    await machine.manager.resume()
    expect(machine.spawned).toEqual([])
  })

  it("waits for a start that is under way instead of starting a second runner beside it", async () => {
    const rebooted = fakeMachine({
      ...withoutSystemd,
      files: { ...UBUNTU, [CONFIG]: await setUpEarlier() }
    })
    await Promise.all([rebooted.manager.start(), rebooted.manager.resume()])
    expect(rebooted.spawned).toHaveLength(1)
  })

  it("calls a desktop running, and stops its old process, when systemd has become available since", async () => {
    const nowWithSystemd = fakeMachine({
      files: {
        ...UBUNTU,
        [CONFIG]: await setUpEarlier(),
        [pidFile]: "4242\n",
        "/proc/4242/cmdline": "node\0/opt/codevisor/cli.js\0desktop\0run"
      },
      alive: [4242]
    })
    expect(await nowWithSystemd.manager.status()).toMatchObject({
      state: "running",
      unmanaged: false
    })
    await nowWithSystemd.manager.start()
    expect(nowWithSystemd.terminated).toEqual([4242])
    expect(nowWithSystemd.files.has(UNIT)).toBe(true)
  })

  it("leaves alone a stopped desktop that something else set up, like the dev container's", async () => {
    const theirs = JSON.stringify({
      vnc: { socket: "/tmp/runtime-root/codevisor-desktop.sock", display: 1, desktop: "xfce" },
      devContainerDesktop: true
    })
    const machine = fakeMachine({
      ...withoutSystemd,
      files: { ...UBUNTU, [CONFIG]: theirs },
      socketAppearsAfterPolls: Number.POSITIVE_INFINITY
    })
    await machine.manager.resume()
    expect(machine.spawned).toEqual([])
  })

  it("does nothing for a desktop that systemd starts", async () => {
    const first = fakeMachine({ files: UBUNTU })
    await first.manager.start()
    const rebooted = fakeMachine({
      files: {
        ...UBUNTU,
        [CONFIG]: first.files.get(CONFIG) ?? "",
        [UNIT]: first.files.get(UNIT) ?? ""
      },
      socketAppearsAfterPolls: Number.POSITIVE_INFINITY
    })
    await rebooted.manager.resume()
    expect(rebooted.spawned).toEqual([])
    expect(rebooted.commands.filter((line) => line.includes("restart"))).toEqual([])
  })
})
