import { describe, expect, it } from "vitest"

import type { PrivateSocket } from "../routes/private-socket.js"
import { desktopIsUp, whyDesktopIsDown } from "./desktop-liveness.js"

const socket = "/run/user/1001/codevisor-desktop.sock"
const runner = 4243
const runnerCommand =
  "/opt/codevisor/bin/node\0/opt/codevisor/cli.js\0desktop\0run\0--data-dir\0/d\0"

interface Machine {
  readonly mark?: string | undefined
  readonly alive?: ReadonlyArray<number>
  readonly commands?: Record<number, string>
}

const machine = ({ mark, alive = [], commands = {} }: Machine) => ({
  readText: (path: string): string | undefined => {
    if (path === `${socket}.ready`) return mark
    const pid = /^\/proc\/(\d+)\/cmdline$/.exec(path)?.[1]
    return pid === undefined ? undefined : commands[Number(pid)]
  },
  processAlive: (pid: number): boolean => alive.includes(pid)
})

const there = (path: string): PrivateSocket => ({ path })
const exposed = (): PrivateSocket => ({ problem: "exposed", detail: "other accounts can open it" })
const running: Machine = {
  mark: `${runner}\n`,
  alive: [runner],
  commands: { [runner]: runnerCommand }
}

describe("whether the desktop is up", () => {
  it("is up with a private socket and a session mark that names a live desktop runner", () => {
    expect(whyDesktopIsDown(machine(running), socket, there)).toBeUndefined()
    expect(desktopIsUp(machine(running), socket, there)).toBe(true)
  })

  it("is down, with the socket's own reason, when the socket is missing or not private", () => {
    expect(whyDesktopIsDown(machine(running), socket, exposed)).toBe("other accounts can open it")
    expect(desktopIsUp(machine(running), socket, exposed)).toBe(false)
  })

  it.each<[string, Machine]>([
    ["there is no session mark", { ...running, mark: undefined }],
    ["the mark names a runner that is gone", { ...running, alive: [] }],
    [
      "the runner's process id now belongs to another program",
      { ...running, commands: { [runner]: "/usr/bin/python3\0server.py\0" } }
    ],
    ["the mark isn't a process id", { ...running, mark: "soon\n" }]
  ])("is down when %s, even with the socket still there", (_name, state) => {
    expect(whyDesktopIsDown(machine(state), socket, there)).toBe("the desktop's session isn't up")
  })
})
