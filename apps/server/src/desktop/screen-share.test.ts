import { describe, expect, it } from "vitest"

import type { PrivateSocket } from "../routes/private-socket.js"
import {
  CONFIG,
  DATA_DIR,
  EVERY_PROGRAM,
  fakeMachine,
  type FakeMachineOptions,
  LOGS_DIR,
  UBUNTU
} from "./desktop-test-support.js"
import { makeScreenShare } from "./screen-share.js"

const socket = "/run/user/1001/codevisor-screen.sock"
const pidFile = `${DATA_DIR}/screen.pid`
const helper = 4242
const sessionProcess = 400
const withTheScreenPrograms = [...EVERY_PROGRAM, "X0tigervnc", "notify-send"]
const desktopEntry = {
  id: "desktop",
  vnc: { socket: "/run/user/1001/codevisor-desktop.sock", display: 1, xauthority: "/x.auth" },
  service: "systemd-user"
}
const screenEntry = { id: "screen", vnc: { socket, name: "Screen" }, service: "server" }
const setUp = `${JSON.stringify({ displays: [screenEntry] })}\n`

const environ = (env: Record<string, string>): string =>
  Object.entries(env)
    .map(([name, value]) => `${name}=${value}\0`)
    .join("")

const aliceAtTheMonitor = {
  XDG_SEAT: "seat0",
  DISPLAY: ":0",
  XAUTHORITY: "/home/codevisor/.Xauthority",
  DBUS_SESSION_BUS_ADDRESS: "unix:path=/run/user/1001/bus"
}

const seated = (account: string) => ({
  "loginctl list-sessions --no-legend": { code: 0, output: ` 2 1002 ${account} seat0 tty2\n` },
  "loginctl show-session 2 -p Name -p Seat -p Class -p Remote -p State": {
    code: 0,
    output: `Name=${account}\nSeat=seat0\nClass=user\nRemote=no\nState=active\n`
  }
})
const someoneElseIsSeated = seated("alice")
const nobodyIsSeated = { "loginctl list-sessions --no-legend": { code: 0, output: "" } }

interface Scene extends FakeMachineOptions {
  readonly tcpPorts?: () => ReadonlyArray<number> | undefined
}

const workstation = (scene: Scene = {}) => {
  const logind: NonNullable<FakeMachineOptions["results"]> = { ...nobodyIsSeated, ...scene.results }
  const machine = fakeMachine({
    programs: withTheScreenPrograms,
    folders: { "/proc": [String(sessionProcess)] },
    ...scene,
    results: logind,
    files: { ...UBUNTU, ...scene.files }
  })
  const clock = { now: 1_000_000 }
  const logIn = (env: Record<string, string> = aliceAtTheMonitor): void => {
    machine.files.set(`/proc/${sessionProcess}/status`, "Uid:\t1001\t1001\n")
    machine.files.set(`/proc/${sessionProcess}/environ`, environ(env))
    Object.assign(logind, seated("codevisor"))
  }
  const endTheSession = (): void => {
    Object.assign(logind, nobodyIsSeated)
    machine.system.terminate(helper)
  }
  const logOut = (): void => {
    machine.files.delete(`/proc/${sessionProcess}/environ`)
    endTheSession()
  }
  const settled = async () => {
    let status = await screen.status()
    while (status.busy !== undefined) status = await screen.status()
    return status
  }
  const locate = (configured: string): PrivateSocket =>
    machine.system.processAlive(helper)
      ? { path: configured }
      : { problem: "missing", detail: `nothing at ${configured}` }
  const screen = makeScreenShare({
    system: machine.system,
    dataDir: DATA_DIR,
    logsDir: LOGS_DIR,
    changed: () => void (machine.changes.count += 1),
    locate,
    tcpPortsOf: () => (scene.tcpPorts === undefined ? [] : scene.tcpPorts()),
    now: () => clock.now
  })
  return { ...machine, screen, logIn, logOut, endTheSession, settled, clock }
}

const refusal = (promise: Promise<unknown>) =>
  promise.then(
    () => undefined,
    (cause: { status?: number; message?: string }) => ({
      status: cause.status,
      message: cause.message
    })
  )

describe("sharing the screen the server's account is logged in at", () => {
  it("records the screen beside the desktop and starts x0vncserver on that session's display", async () => {
    const machine = workstation({
      files: { [CONFIG]: JSON.stringify({ displays: [desktopEntry] }) }
    })
    machine.logIn()

    const status = await machine.screen.setUp()

    expect(JSON.parse(machine.files.get(CONFIG) ?? "").displays).toEqual([
      desktopEntry,
      screenEntry
    ])
    expect(machine.spawned).toEqual([
      {
        command: "env",
        args: [
          "DISPLAY=:0",
          "XAUTHORITY=/home/codevisor/.Xauthority",
          "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1001/bus",
          "X0tigervnc",
          "-display",
          ":0",
          "-rfbunixpath",
          socket,
          "-rfbunixmode",
          "0600",
          "-rfbport",
          "-1",
          "-localhost",
          "-SecurityTypes",
          "None",
          "-AcceptSetDesktopSize=0"
        ],
        logPath: `${LOGS_DIR}/screen.log`
      }
    ])
    expect(status).toEqual({
      state: "running",
      session: "x11",
      display: ":0",
      missing: [],
      others: []
    })
  })

  it("waits when nobody is logged in, and starts sharing when its account logs in", async () => {
    const machine = workstation()

    expect(await machine.screen.setUp()).toMatchObject({ state: "waiting" })
    expect(machine.spawned).toEqual([])

    machine.logIn()
    await machine.screen.follow()

    expect(machine.spawned).toHaveLength(1)
    expect(await machine.screen.status()).toMatchObject({ state: "running", display: ":0" })
  })

  it("leaves a helper alone while it shows the session that is still there", async () => {
    const machine = workstation()
    machine.logIn()
    await machine.screen.setUp()

    await machine.screen.follow()
    await machine.screen.follow()

    expect(machine.spawned).toHaveLength(1)
    expect(machine.terminated).toEqual([])
  })

  it("stops sharing when the session ends, and clears what the helper left behind", async () => {
    const machine = workstation()
    machine.logIn()
    await machine.screen.setUp()
    machine.files.set(socket, "")

    machine.logOut()
    await machine.screen.follow()

    expect(machine.files.has(socket)).toBe(false)
    expect(machine.files.has(pidFile)).toBe(false)
    expect(await machine.screen.status()).toMatchObject({ state: "waiting" })
  })

  it("starts again on the new display when the session comes back somewhere else", async () => {
    const machine = workstation()
    machine.logIn()
    await machine.screen.setUp()

    machine.logIn({ ...aliceAtTheMonitor, DISPLAY: ":2" })
    await machine.screen.follow()

    expect(machine.terminated).toEqual([helper])
    expect(machine.spawned.map((started) => started.args.includes(":2"))).toEqual([false, true])
  })

  it("doesn't take the virtual desktop for the screen", async () => {
    const machine = workstation({
      files: { [CONFIG]: JSON.stringify({ displays: [desktopEntry] }) }
    })
    machine.logIn({ ...aliceAtTheMonitor, DISPLAY: ":1" })

    expect(await machine.screen.setUp()).toMatchObject({ state: "waiting" })
    expect(machine.spawned).toEqual([])
  })

  it("refuses in one sentence when someone else is logged in at the screen", async () => {
    const machine = workstation({ results: someoneElseIsSeated })

    expect(await refusal(machine.screen.setUp())).toEqual({
      status: 409,
      message:
        "alice is logged in at this machine's screen, and Codevisor runs as codevisor here, so it can't share that screen. Set up a separate desktop instead: codevisor desktop setup"
    })
    expect(machine.files.has(CONFIG)).toBe(false)
    expect(await machine.screen.status()).toEqual({ state: "none", missing: [], others: ["alice"] })
  })

  it("refuses a Wayland session, which it can't share yet", async () => {
    const machine = workstation()
    machine.logIn({ XDG_SEAT: "seat0", WAYLAND_DISPLAY: "wayland-0", DISPLAY: ":0" })

    expect(await refusal(machine.screen.setUp())).toMatchObject({
      status: 409,
      message: expect.stringContaining("Wayland")
    })
    expect(machine.files.has(CONFIG)).toBe(false)
  })

  it("names what is missing instead of setting up without it", async () => {
    const machine = workstation({ programs: EVERY_PROGRAM })
    machine.logIn()

    expect(await refusal(machine.screen.setUp())).toEqual({
      status: 409,
      message: "The screen can't be shared until these are installed: x0vncserver, notify-send"
    })
    expect(await machine.screen.status()).toMatchObject({
      state: "none",
      missing: ["x0vncserver", "notify-send"],
      sudo: "passwordless"
    })
  })

  it("stops a helper that listens on the network, says so, and waits before trying again", async () => {
    const machine = workstation({ tcpPorts: () => [5900] })
    machine.logIn()

    const status = await machine.screen.setUp()

    expect(machine.terminated).toEqual([helper])
    expect(status).toMatchObject({
      state: "stopped",
      problem:
        "x0vncserver listens on TCP port 5900, and the screen must only be shared on its socket"
    })

    await machine.screen.follow()
    expect(machine.spawned).toHaveLength(1)

    machine.clock.now += 30_000
    await machine.screen.follow()
    expect(machine.spawned).toHaveLength(2)
  })

  it.each<[string, () => ReadonlyArray<number> | undefined]>([
    ["can't tell which ports the helper has open", () => undefined],
    [
      "finds the helper gone while it looks",
      () => {
        throw new Error("ENOENT: /proc/4242/fd")
      }
    ]
  ])("stops a helper when it %s, instead of sharing unchecked", async (_name, tcpPorts) => {
    const machine = workstation({ tcpPorts })
    machine.logIn()

    expect(await machine.screen.setUp()).toMatchObject({
      state: "stopped",
      problem: "couldn't check that x0vncserver stays off the network"
    })
    expect(machine.terminated).toEqual([helper])
  })

  it("doesn't take processes a session left behind for someone still logged in", async () => {
    const machine = workstation()
    machine.logIn()
    await machine.screen.setUp()

    machine.endTheSession()
    await machine.screen.follow()
    machine.clock.now += 60_000
    await machine.screen.follow()

    expect(machine.spawned).toHaveLength(1)
    expect(await machine.screen.status()).toEqual({ state: "waiting", missing: [], others: [] })
  })

  it("keeps sharing on the socket it recorded, wherever the server's runtime folder is now", async () => {
    const recorded = "/home/codevisor/.codevisor/run/codevisor-screen.sock"
    const entry = { ...screenEntry, vnc: { socket: recorded, name: "Screen" } }
    const machine = workstation({ files: { [CONFIG]: JSON.stringify({ displays: [entry] }) } })
    machine.logIn()

    await machine.screen.follow()

    expect(machine.spawned[0]?.args).toContain(recorded)
    expect(await machine.screen.status()).toMatchObject({ state: "running" })
  })

  it("stops sharing and forgets the screen when it is removed, keeping the desktop", async () => {
    const machine = workstation({
      files: { [CONFIG]: JSON.stringify({ displays: [desktopEntry] }) }
    })
    machine.logIn()
    await machine.screen.setUp()

    const status = await machine.screen.remove()

    expect(machine.terminated).toEqual([helper])
    expect(JSON.parse(machine.files.get(CONFIG) ?? "").displays).toEqual([desktopEntry])
    expect(status).toMatchObject({ state: "none", session: "x11" })
  })

  it("removes the config when the screen was the only display in it", async () => {
    const machine = workstation({ files: { [CONFIG]: setUp } })

    await machine.screen.remove()

    expect(machine.files.has(CONFIG)).toBe(false)
  })
})

describe("telling the person at the screen that someone is viewing it", () => {
  const notification =
    "env DISPLAY=:0 XAUTHORITY=/home/codevisor/.Xauthority DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1001/bus notify-send -a Codevisor Codevisor Someone started viewing this screen."

  it("shows a notification in that session, and not again for every reconnect", async () => {
    const machine = workstation({ files: { [CONFIG]: setUp } })
    machine.logIn()
    const shown = () => machine.commands.filter((line) => line === notification)

    machine.screen.viewerJoined()
    machine.screen.viewerJoined()
    expect(shown()).toHaveLength(1)

    machine.clock.now += 30_000
    machine.screen.viewerJoined()
    expect(shown()).toHaveLength(2)
  })

  it("shows nothing when nobody is logged in", () => {
    const machine = workstation({ files: { [CONFIG]: setUp } })

    machine.screen.viewerJoined()

    expect(machine.commands).toEqual([])
  })
})

describe("installing what sharing the screen needs", () => {
  const install =
    /^sudo -n timeout .* apt-get .* install -y -q --no-install-recommends tigervnc-scraping-server libnotify-bin$/

  it("installs the scraping server and the notifier as root, and says it is busy meanwhile", async () => {
    const installed = Promise.withResolvers<void>()
    const machine = workstation({
      programs: [...EVERY_PROGRAM],
      holds: { prefix: "sudo -n timeout", until: installed.promise }
    })

    expect(await machine.screen.installPackages()).toMatchObject({ busy: "Installing packages" })

    installed.resolve()
    expect(await machine.settled()).not.toHaveProperty("failure")
    expect(machine.commands).toContainEqual(expect.stringMatching(install))
  })

  it("keeps why an install failed until what was missing is there", async () => {
    const machine = workstation({ programs: [...EVERY_PROGRAM], failing: ["sudo -n timeout"] })

    await machine.screen.installPackages()

    expect(await machine.settled()).toMatchObject({ failure: "Installing packages failed:\n" })
  })

  it("leaves it to an administrator when the server's account needs a password", async () => {
    const machine = workstation({ programs: [...EVERY_PROGRAM, "sudo"], failing: ["sudo -n true"] })

    expect(await refusal(machine.screen.installPackages())).toMatchObject({ status: 403 })
    expect(await machine.screen.status()).toMatchObject({ sudo: "password" })
  })
})
