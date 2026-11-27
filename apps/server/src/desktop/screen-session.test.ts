import { describe, expect, it } from "vitest"

import { accountsAtTheScreen, ownGraphicalSession } from "./screen-session.js"

const ownUid = 1000

interface Process {
  readonly uid?: number
  readonly env: Record<string, string>
}

const machine = (processes: Record<number, Process>) => ({
  uid: ownUid,
  listFolder: (path: string): ReadonlyArray<string> =>
    path === "/proc" ? [...Object.keys(processes), "self", "cpuinfo"] : [],
  readText: (path: string): string | undefined => {
    const [, pid, file] = /^\/proc\/(\d+)\/(status|environ)$/.exec(path) ?? []
    const process = processes[Number(pid)]
    if (process === undefined) return undefined
    if (file === "status") return `Name:\tx\nUid:\t${process.uid ?? ownUid}\t0\t0\t0\n`

    return Object.entries(process.env)
      .map(([name, value]) => `${name}=${value}\0`)
      .join("")
  }
})

const atTheMonitor = { XDG_SEAT: "seat0", DISPLAY: ":0", XAUTHORITY: "/home/alice/.Xauthority" }
const bus = "unix:path=/run/user/1000/bus"

describe("the graphical session the server's account has at the screen", () => {
  it("is found from a process of that account that has a seat and a display", () => {
    const system = machine({ 400: { env: { ...atTheMonitor, HOME: "/home/alice" } } })

    expect(ownGraphicalSession(system)).toEqual({
      kind: "x11",
      process: 400,
      display: ":0",
      env: { DISPLAY: ":0", XAUTHORITY: "/home/alice/.Xauthority" }
    })
  })

  it("takes the session bus along when one of the session's processes has it", () => {
    const system = machine({
      400: { env: atTheMonitor },
      401: { env: { ...atTheMonitor, DBUS_SESSION_BUS_ADDRESS: bus } }
    })

    expect(ownGraphicalSession(system)).toMatchObject({
      process: 401,
      env: { DBUS_SESSION_BUS_ADDRESS: bus }
    })
  })

  it.each<[string, Record<number, Process>]>([
    ["another account's session", { 400: { uid: 1001, env: atTheMonitor } }],
    [
      "a login over the network, which has no seat",
      { 400: { env: { DISPLAY: "localhost:10.0" } } }
    ],
    ["a seat with no display, a text console", { 400: { env: { XDG_SEAT: "seat0" } } }],
    [
      "a display Codevisor itself handed out",
      { 400: { env: { ...atTheMonitor, DISPLAY: ":1", CODEVISOR_DESKTOP_DISPLAY: ":1" } } }
    ]
  ])("doesn't take %s for it", (_name, processes) => {
    expect(ownGraphicalSession(machine(processes))).toBeUndefined()
  })

  it("leaves out the display of Codevisor's own virtual desktop", () => {
    const system = machine({
      400: { env: { ...atTheMonitor, DISPLAY: ":1" } },
      401: { env: atTheMonitor }
    })

    expect(ownGraphicalSession(system, { ignoreDisplay: ":1" })?.process).toBe(401)
    expect(ownGraphicalSession(system, { ignoreDisplay: ":0" })?.process).toBe(400)
  })

  it("looks at the process it found last time before searching again", () => {
    const system = machine({ 400: { env: atTheMonitor }, 401: { env: atTheMonitor } })

    expect(ownGraphicalSession(system, { lookFirstAt: 401 })?.process).toBe(401)
    expect(ownGraphicalSession(system, { lookFirstAt: 999 })?.process).toBe(400)
  })

  it.each([
    ["wlroots", { SWAYSOCK: "/run/user/1000/sway-ipc.sock" }],
    ["wlroots", { HYPRLAND_INSTANCE_SIGNATURE: "abc" }],
    ["wayland", {}]
  ])("tells a %s session from an X11 one", (kind, marks) => {
    const system = machine({
      400: { env: { XDG_SEAT: "seat0", WAYLAND_DISPLAY: "wayland-1", DISPLAY: ":0", ...marks } }
    })

    expect(ownGraphicalSession(system)?.kind).toBe(kind)
  })
})

const answering = (answers: Record<string, { code?: number; output: string }>) => ({
  run: async (command: string, args: ReadonlyArray<string>) => {
    const answer = answers[[command, ...args].join(" ")]
    return { code: answer?.code ?? (answer === undefined ? 127 : 0), output: answer?.output ?? "" }
  }
})

const shown = (session: string) =>
  `loginctl show-session ${session} -p Name -p Seat -p Class -p Remote -p State`

describe("who is logged in at the machine's screen", () => {
  it("is everyone logind has seated, without greeters, logins over the network and sessions that are ending", async () => {
    const system = answering({
      "loginctl list-sessions --no-legend": {
        output:
          " 2 1000 alice seat0 tty2\n c1 120 gdm seat0 tty1\n 5 1001 bob - pts/0\n 7 1002 carol seat0 tty3\n"
      },
      [shown("7")]: { output: "Name=carol\nSeat=seat0\nClass=user\nRemote=no\nState=closing\n" },
      [shown("2")]: { output: "Name=alice\nSeat=seat0\nClass=user\nRemote=no\n" },
      [shown("c1")]: { output: "Name=gdm\nSeat=seat0\nClass=greeter\nRemote=no\n" },
      [shown("5")]: { output: "Name=bob\nSeat=\nClass=user\nRemote=yes\n" }
    })

    expect(await accountsAtTheScreen(system)).toEqual(["alice"])
  })

  it("falls back to who is recorded on a display when logind has no sessions", async () => {
    const system = answering({
      "loginctl list-sessions --no-legend": { output: "" },
      who: {
        output:
          "alice    tty7         2026-11-26 17:18 (:0)\nlightdm  :1           2026-11-26 17:10\nbob      pts/0        2026-11-26 17:19 (10.0.0.4)\n"
      }
    })

    expect(await accountsAtTheScreen(system)).toEqual(["alice"])
  })

  it("is nobody when both answer and list no one", async () => {
    const system = answering({
      "loginctl list-sessions --no-legend": { output: "" },
      who: { output: "" }
    })

    expect(await accountsAtTheScreen(system)).toEqual([])
  })

  it("is unknown when neither can be asked", async () => {
    expect(await accountsAtTheScreen(answering({}))).toBeUndefined()
  })
})
