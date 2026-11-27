import { describe, expect, it } from "vitest"

import { CONFIG, EVERY_PROGRAM, LOGS_DIR } from "./desktop-test-support.js"
import {
  desktopEntry,
  helper,
  pidFile,
  refusal,
  screenEntry,
  setUp,
  socket,
  someoneElseIsSeated,
  aliceAtTheMonitor,
  workstation
} from "./screen-share-test-support.js"

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
    expect(await machine.screen.status({ askSudo: true })).toMatchObject({
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
    const recorded = "/home/codevisor/.codevisor/run/codevisor-screen-e494c633d5a9.sock"
    const entry = { ...screenEntry, vnc: { socket: recorded, name: "Screen" } }
    const machine = workstation({ files: { [CONFIG]: JSON.stringify({ displays: [entry] }) } })
    machine.logIn()

    await machine.screen.follow()

    expect(machine.spawned[0]?.args).toContain(recorded)
    expect(await machine.screen.status()).toMatchObject({ state: "running" })
  })

  it("stops sharing when its account has left the screen, though processes still carry the session", async () => {
    const machine = workstation()
    machine.logIn()
    await machine.screen.setUp()

    machine.leaveTheScreen()
    expect(await machine.screen.status()).toMatchObject({ state: "waiting" })
    await machine.screen.follow()

    expect(machine.terminated).toEqual([helper])
    expect(await machine.screen.status()).toMatchObject({ state: "waiting" })
  })

  it("starts the helper again when its socket is gone though the helper still runs", async () => {
    const machine = workstation()
    machine.logIn()
    await machine.screen.setUp()

    machine.socketState.gone = true
    await machine.screen.follow()

    expect(machine.terminated).toEqual([helper])
    expect(machine.spawned).toHaveLength(2)
  })

  it("kills a helper that ignores being asked to stop, and forgets it only once it has gone", async () => {
    const machine = workstation({ ignoresSigterm: [helper] })
    machine.logIn()
    await machine.screen.setUp()

    machine.leaveTheScreen()
    await machine.screen.follow()

    expect([machine.terminated, machine.killed]).toEqual([[helper], [helper]])
    expect(machine.files.has(pidFile)).toBe(false)
  })

  it("names its socket after its data folder, so two servers on one account don't share one", async () => {
    const machine = workstation()
    machine.logIn()

    await machine.screen.setUp()

    expect(JSON.parse(machine.files.get(CONFIG) ?? "").displays[0].vnc.socket).toBe(socket)
  })

  it("leaves alone a socket it neither recorded nor started", async () => {
    const otherServers = "/run/user/1001/codevisor-screen-54e65e34be47.sock"
    const machine = workstation({ files: { [socket]: "", [otherServers]: "" } })
    machine.logIn()

    await machine.screen.follow()

    expect([machine.files.has(socket), machine.files.has(otherServers)]).toEqual([true, true])
  })

  it("asks logind about the screen once for each status, and checks the programs once a while", async () => {
    const machine = workstation()
    machine.logIn()

    const probes = () => machine.asked.filter((line) => line.startsWith("sh -c command -v")).length
    await machine.screen.status()
    const afterOne = probes()
    await machine.screen.status()

    const listed = machine.asked.filter((line) => line === "loginctl list-sessions --no-legend")
    expect(listed).toHaveLength(2)
    expect(probes()).toBe(afterOne)
  })

  it("goes by the session type logind reports, not by one process's variables", async () => {
    const machine = workstation()
    machine.logIn(aliceAtTheMonitor, "wayland")

    expect(await refusal(machine.screen.setUp())).toMatchObject({
      status: 409,
      message: expect.stringContaining("Wayland")
    })
  })

  it("stops a helper it started on another socket than the one now recorded", async () => {
    const elsewhere = "/home/codevisor/.codevisor/run/codevisor-screen-e494c633d5a9.sock"
    const entry = { ...screenEntry, vnc: { socket: elsewhere, name: "Screen" } }
    const machine = workstation({ files: { [CONFIG]: JSON.stringify({ displays: [entry] }) } })
    machine.logIn()
    await machine.screen.follow()

    machine.files.set(CONFIG, JSON.stringify({ displays: [desktopEntry] }))
    await machine.screen.follow()

    expect(machine.terminated).toEqual([helper])
    expect(machine.files.has(pidFile)).toBe(false)
  })

  it("waits before starting again a helper that stopped right after it started", async () => {
    const machine = workstation()
    machine.logIn()
    await machine.screen.setUp()

    machine.system.terminate(helper)
    await machine.screen.follow()
    expect(machine.spawned).toHaveLength(1)
    expect(await machine.screen.status()).toMatchObject({
      state: "stopped",
      problem: "x0vncserver stopped right after it started; see its log"
    })

    machine.clock.now += 30_000
    await machine.screen.follow()
    expect(machine.spawned).toHaveLength(2)
  })

  it.each([
    ["can't be read", "{ not json"],
    ["isn't an object", "[]"]
  ])("leaves a config that %s alone, and says so", async (_name, text) => {
    const machine = workstation({ files: { [CONFIG]: text } })
    machine.logIn()

    expect(await refusal(machine.screen.setUp())).toMatchObject({ status: 409 })
    await machine.screen.remove()

    expect(machine.files.get(CONFIG)).toBe(text)
  })

  it("keeps a helper that shows the same display, written :0.0 instead of :0", async () => {
    const machine = workstation()
    machine.logIn()
    await machine.screen.setUp()

    machine.logIn({ ...aliceAtTheMonitor, DISPLAY: ":0.0" })
    await machine.screen.follow()

    expect([machine.spawned.length, machine.terminated]).toEqual([1, []])
  })

  it("starts sharing a new login at once, without the wait a quick death in the old one set", async () => {
    const machine = workstation()
    machine.logIn()
    await machine.screen.setUp()
    machine.system.terminate(helper)
    await machine.screen.follow()
    expect(machine.spawned).toHaveLength(1)

    machine.logIn(aliceAtTheMonitor, "x11", { process: 401, session: "5" })
    await machine.screen.follow()

    expect(machine.spawned).toHaveLength(2)
  })

  it("refuses to forget the screen while its helper can't be stopped", async () => {
    const machine = workstation({ unkillable: [helper] })
    machine.logIn()
    await machine.screen.setUp()

    expect(await refusal(machine.screen.remove())).toMatchObject({
      status: 500,
      message: "the screen's VNC server (process 4242) doesn't stop, even when killed"
    })
    expect(JSON.parse(machine.files.get(CONFIG) ?? "").displays).toEqual([screenEntry])
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
