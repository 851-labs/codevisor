import type { PrivateSocket } from "../routes/private-socket.js"
import {
  DATA_DIR,
  EVERY_PROGRAM,
  fakeMachine,
  type FakeMachineOptions,
  LOGS_DIR,
  UBUNTU
} from "./desktop-test-support.js"
import { makeScreenShare } from "./screen-share.js"

export const socket = "/run/user/1001/codevisor-screen-e494c633d5a9.sock"
export const pidFile = `${DATA_DIR}/screen.pid`
export const helper = 4242
const sessionProcess = 400
const compositor = 402
const withTheScreenPrograms = [...EVERY_PROGRAM, "X0tigervnc", "notify-send"]
export const desktopEntry = {
  id: "desktop",
  vnc: { socket: "/run/user/1001/codevisor-desktop.sock", display: 1, xauthority: "/x.auth" },
  service: "systemd-user"
}
export const screenEntry = { id: "screen", vnc: { socket, name: "Screen" }, service: "server" }
export const setUp = `${JSON.stringify({ displays: [screenEntry] })}\n`

const environ = (env: Record<string, string>): string =>
  Object.entries(env)
    .map(([name, value]) => `${name}=${value}\0`)
    .join("")

export const onSway = {
  XDG_SEAT: "seat0",
  WAYLAND_DISPLAY: "wayland-1",
  XDG_RUNTIME_DIR: "/run/user/1001",
  DBUS_SESSION_BUS_ADDRESS: "unix:path=/run/user/1001/bus"
}

export const aliceAtTheMonitor = {
  XDG_SEAT: "seat0",
  DISPLAY: ":0",
  XAUTHORITY: "/home/codevisor/.Xauthority",
  DBUS_SESSION_BUS_ADDRESS: "unix:path=/run/user/1001/bus"
}

export const seated = (account: string, type = "x11", display = ":0", id = "2") => ({
  "loginctl list-sessions --no-legend": { code: 0, output: ` ${id} 1002 ${account} seat0 tty2\n` },
  [`loginctl show-session ${id} -p Id -p Name -p Seat -p Class -p Remote -p State -p Type -p Display`]:
    {
      code: 0,
      output: `Id=${id}\nName=${account}\nSeat=seat0\nClass=user\nRemote=no\nState=active\nType=${type}\nDisplay=${type === "x11" ? display : ""}\n`
    }
})

export interface Login {
  readonly process: number
  readonly session: string
}

const firstLogin: Login = { process: sessionProcess, session: "2" }
export const someoneElseIsSeated = seated("alice")
const nobodyIsSeated = { "loginctl list-sessions --no-legend": { code: 0, output: "" } }

interface Scene extends FakeMachineOptions {
  readonly tcpPorts?: () => ReadonlyArray<number> | undefined
}

export const workstation = (scene: Scene = {}) => {
  const logind: NonNullable<FakeMachineOptions["results"]> = { ...nobodyIsSeated, ...scene.results }
  const machine = fakeMachine({
    programs: withTheScreenPrograms,
    folders: { "/proc": [String(sessionProcess), String(sessionProcess + 1), String(compositor)] },
    ...scene,
    results: logind,
    files: { ...UBUNTU, ...scene.files }
  })
  const clock = { now: 1_000_000 }
  const socketState = { gone: false }
  const asked: string[] = []
  const system = {
    ...machine.system,
    run: (command: string, args: ReadonlyArray<string>, timeoutMs?: number) => {
      asked.push([command, ...args].join(" "))
      return machine.system.run(command, args, timeoutMs)
    },
    spawnDetached: (command: string, args: ReadonlyArray<string>, logPath: string) => {
      socketState.gone = false
      const pid = machine.system.spawnDetached(command, args, logPath)
      const assigned = args.filter((arg) => /^[A-Z_]+=/.test(arg))
      machine.files.set(`/proc/${pid}/environ`, assigned.map((pair) => `${pair}\0`).join(""))
      return pid
    }
  }
  const started = { by: 1 }
  const statusOf = (): string => `PPid:\t${started.by}\nUid:\t1001\t1001\n`
  const logIn = (
    env: Record<string, string> = aliceAtTheMonitor,
    type = env["WAYLAND_DISPLAY"] === undefined ? "x11" : "wayland",
    login: Login = firstLogin
  ): void => {
    machine.files.set(`/proc/${login.process}/status`, statusOf())
    machine.files.set(`/proc/${login.process}/environ`, environ(env))
    machine.files.set(
      `/proc/${login.process}/cgroup`,
      `0::/user.slice/user-1001.slice/session-${login.session}.scope\n`
    )
    Object.assign(logind, seated("codevisor", type, env["DISPLAY"], login.session))
  }
  const runCompositor = (name: string, session = firstLogin.session): void => {
    started.by = compositor
    machine.files.set(`/proc/${sessionProcess}/status`, statusOf())
    machine.files.set(`/proc/${compositor}/status`, "Uid:\t1001\t1001\n")
    machine.files.set(`/proc/${compositor}/comm`, `${name}\n`)
    machine.files.set(
      `/proc/${compositor}/cgroup`,
      `0::/user.slice/user-1001.slice/session-${session}.scope\n`
    )
  }
  const leaveTheScreen = (): void => void Object.assign(logind, nobodyIsSeated)
  const endTheSession = (): void => {
    leaveTheScreen()
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
    machine.system.processAlive(helper) && !socketState.gone
      ? { path: configured }
      : { problem: "missing", detail: `nothing at ${configured}` }
  const screen = makeScreenShare({
    system,
    dataDir: DATA_DIR,
    logsDir: LOGS_DIR,
    changed: () => void (machine.changes.count += 1),
    locate,
    tcpPortsOf: () => (scene.tcpPorts === undefined ? [] : scene.tcpPorts()),
    now: () => clock.now
  })
  return {
    ...machine,
    screen,
    logIn,
    logOut,
    leaveTheScreen,
    runCompositor,
    endTheSession,
    settled,
    clock,
    socketState,
    asked
  }
}

export const refusal = (promise: Promise<unknown>) =>
  promise.then(
    () => undefined,
    (cause: { status?: number; message?: string }) => ({
      status: cause.status,
      message: cause.message
    })
  )
