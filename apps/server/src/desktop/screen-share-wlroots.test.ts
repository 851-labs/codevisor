import { describe, expect, it } from "vitest"

import { CONFIG, EVERY_PROGRAM, LOGS_DIR } from "./desktop-test-support.js"
import { onSway, refusal, screenEntry, socket, workstation } from "./screen-share-test-support.js"

const withWayvnc = [...EVERY_PROGRAM, "wayvnc", "notify-send"]
const wayvncWithAControlSocket = {
  "wayvnc --help": { code: 0, output: "  -S,--socket=<path>        Control socket path.\n" }
}

const sway = (scene: Parameters<typeof workstation>[0] = {}) => {
  const machine = workstation({ programs: withWayvnc, ...scene })
  machine.logIn(onSway)
  machine.runCompositor("sway")
  return machine
}

const wayvncCommand = (controlSocket: ReadonlyArray<string>) => ({
  command: "sh",
  args: [
    "-c",
    'umask 077 && exec "$@"',
    "sh",
    "env",
    "WAYLAND_DISPLAY=wayland-1",
    "XDG_RUNTIME_DIR=/run/user/1001",
    "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1001/bus",
    "wayvnc",
    "--config=/dev/null",
    "--render-cursor",
    ...controlSocket,
    "--unix-socket",
    socket
  ],
  logPath: `${LOGS_DIR}/screen.log`
})

describe("sharing the screen of a wlroots session", () => {
  it("starts wayvnc on the session's Wayland display, with only private files and no config of its own", async () => {
    const machine = sway({ results: wayvncWithAControlSocket })

    const status = await machine.screen.setUp()

    expect(machine.spawned).toEqual([wayvncCommand([`--socket=${socket}.ctl`])])
    expect(status).toEqual({
      state: "running",
      session: "wlroots",
      display: "wayland-1",
      missing: [],
      others: []
    })
  })

  it("leaves out the control socket on a wayvnc too old to have one", async () => {
    const machine = sway()

    await machine.screen.setUp()

    expect(machine.spawned).toEqual([wayvncCommand([])])
  })

  it("keeps the helper while it shows the same Wayland display, and starts again on another", async () => {
    const machine = sway()
    await machine.screen.setUp()

    await machine.screen.follow()
    expect(machine.spawned).toHaveLength(1)

    machine.logIn({ ...onSway, WAYLAND_DISPLAY: "wayland-2" })
    await machine.screen.follow()
    expect(machine.terminated).toEqual([4242])
    expect(machine.spawned.at(-1)?.args).toContain("WAYLAND_DISPLAY=wayland-2")
  })

  it("doesn't take a process that only names the socket for its helper", async () => {
    const machine = sway()
    await machine.screen.setUp()
    machine.files.set("/proc/4242/cmdline", ["stat", socket].join("\0"))

    machine.logIn({ ...onSway, WAYLAND_DISPLAY: "wayland-2" })
    await machine.screen.follow()

    expect(machine.terminated).toEqual([])
  })

  it("keeps sharing when an app started for XWayland alone is the session's newest process", async () => {
    const machine = sway()
    await machine.screen.setUp()

    const { WAYLAND_DISPLAY: _, ...xwaylandOnly } = { ...onSway, DISPLAY: ":0" }
    machine.logIn(xwaylandOnly, "wayland", { process: 401, session: "2" })
    machine.files.set("/proc/401/stat", `401 (x) S ${"0 ".repeat(18)}99 0 0\n`)
    await machine.screen.follow()

    expect(machine.terminated).toEqual([])
    expect((await machine.screen.status()).state).toBe("running")
  })

  it("asks for wayvnc, not x0vncserver, when it is missing", async () => {
    const machine = sway({ programs: [...EVERY_PROGRAM, "X0tigervnc", "notify-send"] })

    expect(await refusal(machine.screen.setUp())).toEqual({
      status: 409,
      message: "The screen can't be shared until these are installed: wayvnc"
    })
    expect(machine.files.has(CONFIG)).toBe(false)
  })

  it("installs wayvnc for a wlroots session", async () => {
    const machine = sway({ programs: [...EVERY_PROGRAM] })

    await machine.screen.installPackages()
    await machine.settled()

    expect(machine.commands).toContainEqual(
      expect.stringMatching(
        /apt-get .* install -y -q --no-install-recommends wayvnc libnotify-bin$/
      )
    )
  })

  it.each(["gnome-shell", "kwin_wayland"])(
    "still refuses a Wayland session whose compositor is %s",
    async (name) => {
      const machine = workstation({ programs: withWayvnc })
      machine.logIn(onSway)
      machine.runCompositor(name)

      expect(await refusal(machine.screen.setUp())).toMatchObject({
        status: 409,
        message: expect.stringContaining("Wayland desktop that Codevisor can't share yet")
      })
    }
  )

  it("installs nothing for a Wayland session it can't share", async () => {
    const machine = workstation({ programs: [...EVERY_PROGRAM] })
    machine.logIn(onSway)
    machine.runCompositor("gnome-shell")

    expect(await refusal(machine.screen.installPackages())).toMatchObject({ status: 409 })
    expect(machine.commands.filter((command) => command.includes("install"))).toEqual([])
  })

  it("records the screen like any other", async () => {
    const machine = sway()

    await machine.screen.setUp()

    expect(JSON.parse(machine.files.get(CONFIG) ?? "").displays).toEqual([screenEntry])
  })
})
