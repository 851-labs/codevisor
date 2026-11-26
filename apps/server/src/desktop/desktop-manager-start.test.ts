import { describe, expect, it } from "vitest"

import {
  CONFIG,
  DATA_DIR,
  fakeMachine,
  type FakeMachineOptions,
  LOGS_DIR,
  RUNNER,
  UBUNTU,
  UNIT
} from "./desktop-test-support.js"

const bare = ["apt-get", "sudo"]

const stoppedOnDisplay2 = async (display2: Partial<FakeMachineOptions>) => {
  const machine = fakeMachine({ files: UBUNTU, existing: ["/tmp/.X11-unix/X1"] })
  await machine.manager.start()
  return fakeMachine({
    ...display2,
    files: { ...UBUNTU, [CONFIG]: machine.files.get(CONFIG) ?? "", ...display2.files },
    existing: ["/tmp/.X11-unix/X1", "/tmp/.X11-unix/X2"],
    socketAppearsAfterPolls: 1
  })
}

const ourXvnc = "Xvnc\0:2\0-rfbunixpath\0/run/user/1001/codevisor-desktop.sock"

const moved = (unit: string) => unit.replaceAll("/opt/codevisor/", "/updates/1.2.3/runtime/")

const reloadsAndRestarts = (commands: string[]) =>
  commands.filter((line) => line.includes("daemon-reload") || line.includes("restart"))

const runningFromAnOldFolder = async () => {
  const first = fakeMachine({ files: UBUNTU })
  await first.manager.start()
  const machine = fakeMachine({
    files: {
      ...UBUNTU,
      [CONFIG]: first.files.get(CONFIG) ?? "",
      [UNIT]: moved(first.files.get(UNIT) ?? "")
    }
  })
  return { machine, current: first.files.get(UNIT) }
}

describe("starting the desktop as the server's own account", () => {
  it("writes the config in the server's data folder and a boot service of that account, then waits for the socket", async () => {
    const machine = fakeMachine({ files: UBUNTU, socketAppearsAfterPolls: 3 })
    const status = await machine.manager.start()

    expect(JSON.parse(machine.files.get(CONFIG) ?? "")).toEqual({
      vnc: {
        socket: "/run/user/1001/codevisor-desktop.sock",
        display: 1,
        xauthority: "/run/user/1001/codevisor-desktop.xauth",
        name: "Desktop",
        desktop: "xfce",
        defaultSize: "1440x900"
      },
      service: "systemd-user"
    })
    expect(machine.files.get(UNIT)).toContain(
      `ExecStart="${RUNNER.program}" "/opt/codevisor/cli.js" "desktop" "run" "--data-dir" "${DATA_DIR}"`
    )
    expect(machine.files.get(UNIT)).toContain("WantedBy=default.target")
    expect(
      machine.commands.filter(
        (line) => line.startsWith("systemctl --user") && !line.endsWith("show-environment")
      )
    ).toEqual([
      "systemctl --user daemon-reload",
      "systemctl --user enable codevisor-desktop.service",
      "systemctl --user restart codevisor-desktop.service"
    ])
    expect(
      machine.commands.some((line) => line.startsWith("sudo") && line !== "sudo -n true")
    ).toBe(false)
    expect(status).toMatchObject({ state: "running", display: 1, unmanaged: false })
    expect(machine.changes.count).toBe(1)
  })

  it("takes the next display when an old desktop holds the first one", async () => {
    const machine = fakeMachine({ files: UBUNTU, existing: ["/tmp/.X11-unix/X1", "/tmp/.X2-lock"] })
    expect(await machine.manager.start()).toMatchObject({ state: "running", display: 3 })
  })

  it("knows its own X server by the socket in its config, wherever it would put a new one", async () => {
    const again = await stoppedOnDisplay2({
      files: { "/tmp/.X2-lock": "  777\n", "/proc/777/cmdline": ourXvnc },
      alive: [777],
      env: {}
    })
    expect(await again.manager.start()).toMatchObject({ display: 2 })
  })

  it.each([
    { name: "its old X server left a lock behind", files: { "/tmp/.X2-lock": "  777\n" } },
    {
      name: "its own X server still holds it",
      files: { "/tmp/.X2-lock": "  777\n", "/proc/777/cmdline": ourXvnc },
      alive: [777]
    }
  ])("keeps its display when it is set up again and $name", async (display2) => {
    const again = await stoppedOnDisplay2(display2)
    expect(await again.manager.start()).toMatchObject({ display: 2 })
  })

  it.each([
    {
      name: "another X server",
      files: { "/tmp/.X2-lock": "  777\n", "/proc/777/cmdline": "Xorg\0:2" },
      alive: [777]
    },
    { name: "something that left no lock to read", files: {} }
  ])("moves to a free display when $name has taken the one it had", async (display2) => {
    const again = await stoppedOnDisplay2(display2)
    expect(await again.manager.start()).toMatchObject({ state: "running", display: 3 })
  })

  it("keeps the name and size someone gave the desktop when it is set up again", async () => {
    const machine = fakeMachine({ files: UBUNTU })
    await machine.manager.start()
    const renamed = JSON.parse(machine.files.get(CONFIG) ?? "")
    renamed.vnc.name = "Lab bench"
    renamed.vnc.defaultSize = "1920x1080"
    const again = fakeMachine({
      files: { ...UBUNTU, [CONFIG]: JSON.stringify(renamed) },
      socketAppearsAfterPolls: 1
    })
    await again.manager.start()
    expect(JSON.parse(again.files.get(CONFIG) ?? "").vnc).toMatchObject({
      name: "Lab bench",
      defaultSize: "1920x1080"
    })
  })

  it("replaces a running desktop it didn't set up only when asked to, and leaves it shared otherwise", async () => {
    const theirs = JSON.stringify({
      vnc: { socket: "/home/dev/desk.sock", display: 4, name: "Bench", defaultSize: "1280x800" }
    })
    const machine = fakeMachine({ files: { ...UBUNTU, [CONFIG]: theirs } })
    expect(await machine.manager.status()).toMatchObject({ state: "running", unmanaged: true })
    await expect(machine.manager.start()).rejects.toMatchObject({ status: 409 })
    const down = fakeMachine({
      files: { ...UBUNTU, [CONFIG]: theirs },
      socketAppearsAfterPolls: Number.POSITIVE_INFINITY
    })
    expect(await down.manager.status()).toMatchObject({ state: "stopped", unmanaged: true })
    await expect(down.manager.start()).rejects.toMatchObject({ status: 409 })
    expect(down.files.get(CONFIG)).toBe(theirs)
    expect(machine.files.get(CONFIG)).toBe(theirs)
    expect(machine.files.has(UNIT)).toBe(false)

    await machine.manager.start({ replaceUnmanaged: true })
    expect(JSON.parse(machine.files.get(CONFIG) ?? "")).toMatchObject({
      vnc: {
        socket: "/run/user/1001/codevisor-desktop.sock",
        name: "Bench",
        defaultSize: "1280x800"
      },
      service: "systemd-user"
    })
  })

  it("leaves a running desktop alone when it is set up again, so nothing open in it closes", async () => {
    const machine = fakeMachine({ files: UBUNTU })
    await machine.manager.start()
    machine.commands.length = 0

    expect(await machine.manager.start()).toMatchObject({ state: "running", display: 1 })
    expect(machine.commands.filter((line) => line.includes("restart"))).toEqual([])
    expect(machine.changes.count).toBe(1)
  })

  it("takes a free display instead of the one in a config something else wrote", async () => {
    const theirs = JSON.stringify({
      vnc: { socket: "/tmp/runtime-root/codevisor-desktop.sock", display: 1, desktop: "xfce" },
      devContainerDesktop: true
    })
    const machine = fakeMachine({
      files: { ...UBUNTU, [CONFIG]: theirs },
      existing: ["/tmp/.X11-unix/X1"],
      socketAppearsAfterPolls: 1
    })
    expect(await machine.manager.start({ replaceUnmanaged: true })).toMatchObject({ display: 2 })
  })

  it("refuses to start while programs are missing, and changes nothing", async () => {
    const machine = fakeMachine({ programs: [...bare, "Xvnc"], files: UBUNTU })
    await expect(machine.manager.start()).rejects.toMatchObject({
      status: 409,
      message:
        "The desktop can't start until these are installed: startxfce4, xfconf-query, dbus-run-session, xclip, python3"
    })
    expect(machine.files.has(CONFIG)).toBe(false)
    expect(machine.files.has(UNIT)).toBe(false)
  })

  it("says the desktop didn't start, with its last log lines, when the socket never appears", async () => {
    const journal = "journalctl --user -u codevisor-desktop.service -n 15 --no-pager -o cat"
    const machine = fakeMachine({
      files: UBUNTU,
      socketAppearsAfterPolls: Number.POSITIVE_INFINITY,
      results: { [journal]: { code: 0, output: "Xvnc didn't open its socket\n" } }
    })
    await expect(machine.manager.start()).rejects.toMatchObject({
      status: 500,
      message: "The desktop didn't start.\nXvnc didn't open its socket"
    })
    expect(machine.changes.count).toBe(1)
  })

  it("doesn't call a desktop ready when its socket appears and is gone again a moment later", async () => {
    const machine = fakeMachine({ files: UBUNTU, socketVanishesAfterPolls: 5 })
    await expect(machine.manager.start()).rejects.toMatchObject({ status: 500 })
  })

  it("runs the desktop as a plain process, with its own runtime folder, where there is no systemd", async () => {
    const machine = fakeMachine({
      files: UBUNTU,
      failing: ["systemctl --user show-environment"],
      env: {}
    })
    const status = await machine.manager.start()
    expect(machine.spawned).toEqual([
      { command: RUNNER.program, args: RUNNER.args, logPath: `${LOGS_DIR}/desktop.log` }
    ])
    expect(machine.files.get(`${DATA_DIR}/desktop.pid`)).toBe("4242\n")
    expect(JSON.parse(machine.files.get(CONFIG) ?? "")).toMatchObject({
      vnc: { socket: "/home/codevisor/.codevisor/run/codevisor-desktop.sock" },
      service: "process"
    })
    expect(machine.files.has(UNIT)).toBe(false)
    expect(status).toMatchObject({ startsAtBoot: false, logHint: `${LOGS_DIR}/desktop.log` })
  })
})

describe("the boot service after the server moved to another folder", () => {
  it("is pointed at the server's current folder when the server starts, without restarting the desktop", async () => {
    const { machine, current } = await runningFromAnOldFolder()
    await machine.manager.resume()
    expect(machine.files.get(UNIT)).toBe(current)
    expect(reloadsAndRestarts(machine.commands)).toEqual(["systemctl --user daemon-reload"])
  })

  it("is pointed at the server's current folder by a setup that finds the desktop running", async () => {
    const { machine, current } = await runningFromAnOldFolder()
    await machine.manager.start()
    expect(machine.files.get(UNIT)).toBe(current)
    expect(reloadsAndRestarts(machine.commands)).toEqual(["systemctl --user daemon-reload"])
  })

  it("is left alone, and so is its desktop, when it belongs to another Codevisor server on this account", async () => {
    const first = fakeMachine({ files: UBUNTU })
    await first.manager.start()
    const theirs = (first.files.get(UNIT) ?? "").replaceAll(DATA_DIR, "/home/codevisor/alpha/data")
    const machine = fakeMachine({ files: { ...UBUNTU, [UNIT]: theirs } })

    await machine.manager.resume()
    await expect(machine.manager.start()).rejects.toMatchObject({
      status: 409,
      message: expect.stringContaining("Another Codevisor server on this account")
    })
    await machine.manager.remove()
    expect(machine.files.get(UNIT)).toBe(theirs)
    expect(
      machine.commands.filter(
        (line) => line.startsWith("systemctl --user") && !line.endsWith("show-environment")
      )
    ).toEqual([])
    expect(await machine.manager.status()).toMatchObject({ state: "none", unmanaged: false })
  })

  it("is left alone while it already points there", async () => {
    const first = fakeMachine({ files: UBUNTU })
    await first.manager.start()
    first.commands.length = 0
    await first.manager.resume()
    expect(reloadsAndRestarts(first.commands)).toEqual([])
  })
})
