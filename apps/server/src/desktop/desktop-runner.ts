import { type ChildProcess, spawn } from "node:child_process"
import { existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs"
import { dirname } from "node:path"

import { readDesktopSetup } from "../routes/screen-sharing-vnc.js"
import type { ScreenSharingVNCConfig } from "../server-context-types.js"
import { DESKTOP_SIZE, x11SocketOf } from "./desktop-layout.js"
import { listeningPorts } from "./listening-ports.js"
import { xauthorityEntry } from "./xauthority.js"

const ownerOnlyFile = 0o600
const ownerOnlyFolder = 0o700
const vncBasePort = 5900
const readyPollMs = 100
const readyPolls = 100
const portSettleMs = 1000
const stopGraceMs = 3000
const sessionCommand =
  "xfconf-query -c xfwm4 -p /general/use_compositing -n -t bool -s false; exec startxfce4"

export const runDesktop = async (dataDir: string, log: (line: string) => void): Promise<number> => {
  const setup = readDesktopSetup(dataDir)
  if (setup.kind !== "ready" || setup.config.display === undefined) {
    log("No desktop is set up in this data folder. Run: codevisor desktop setup")
    return 1
  }

  return new DesktopRun(desktopOf(setup.config, setup.config.display), log).untilItEnds()
}

interface RunningDesktop {
  readonly socket: string
  readonly xauthority: string
  readonly display: number
  readonly size: string
}

const desktopOf = (config: ScreenSharingVNCConfig, display: number): RunningDesktop => ({
  socket: config.socket,
  xauthority: config.xauthority ?? `${config.socket}.xauth`,
  display,
  size:
    config.defaultWidth === undefined || config.defaultHeight === undefined
      ? DESKTOP_SIZE
      : `${config.defaultWidth}x${config.defaultHeight}`
})

class DesktopRun {
  private readonly children: ChildProcess[] = []
  private ended: ((code: number) => void) | undefined
  private stopping = false

  constructor(
    private readonly desktop: RunningDesktop,
    private readonly log: (line: string) => void
  ) {}

  untilItEnds(): Promise<number> {
    return new Promise((resolve) => {
      this.ended = resolve
      for (const signal of ["SIGTERM", "SIGINT", "SIGHUP"] as const)
        process.once(signal, () => this.stop(0))
      this.start().catch((cause: unknown) => {
        this.log(cause instanceof Error ? cause.message : String(cause))
        this.stop(1)
      })
    })
  }

  private async start(): Promise<void> {
    this.writeCookie()
    this.watch("Xvnc", this.xvncArguments(), {})
    await this.xvncIsUp()
    await this.tcpStaysClosed()
    this.watch("dbus-run-session", ["--", "sh", "-c", sessionCommand], this.sessionEnvironment())
    this.log(`The desktop is running on display :${this.desktop.display}`)
  }

  private writeCookie(): void {
    mkdirSync(dirname(this.desktop.socket), { recursive: true, mode: ownerOnlyFolder })
    rmSync(this.desktop.socket, { force: true })
    rmSync(this.desktop.xauthority, { force: true })
    writeFileSync(this.desktop.xauthority, xauthorityEntry(), { mode: ownerOnlyFile })
  }

  private xvncArguments(): string[] {
    return [
      `:${this.desktop.display}`,
      "-auth",
      this.desktop.xauthority,
      "-rfbunixpath",
      this.desktop.socket,
      "-rfbunixmode",
      "0600",
      "-rfbport",
      "-1",
      "-localhost",
      "-nolisten",
      "tcp",
      "-geometry",
      this.desktop.size,
      "-depth",
      "24",
      "-SecurityTypes",
      "None"
    ]
  }

  private sessionEnvironment(): Record<string, string> {
    return {
      DISPLAY: `:${this.desktop.display}`,
      XAUTHORITY: this.desktop.xauthority,
      XDG_SESSION_TYPE: "x11",
      XDG_RUNTIME_DIR: process.env["XDG_RUNTIME_DIR"] ?? dirname(this.desktop.socket)
    }
  }

  private watch(program: string, args: string[], env: Record<string, string>): void {
    const child = spawn(program, args, {
      env: { ...process.env, ...env },
      stdio: ["ignore", "inherit", "inherit"]
    })
    this.children.push(child)
    child.once("error", (error) => {
      this.log(`${program} couldn't start: ${error.message}`)
      this.stop(1)
    })
    child.once("exit", (code) => {
      if (!this.stopping) this.log(`${program} stopped (exit ${code ?? "by a signal"})`)
      this.stop(1)
    })
  }

  private async xvncIsUp(): Promise<void> {
    for (let poll = 0; poll < readyPolls; poll += 1) {
      if (this.stopping) throw new Error("Xvnc didn't start")
      if (existsSync(this.desktop.socket) && existsSync(x11SocketOf(this.desktop.display))) return

      await sleep(readyPollMs)
    }
    throw new Error("Xvnc didn't open its socket")
  }

  private async tcpStaysClosed(): Promise<void> {
    this.refuseAnOpenTcpPort()
    await sleep(portSettleMs)
    this.refuseAnOpenTcpPort()
  }

  private refuseAnOpenTcpPort(): void {
    const port = vncBasePort + this.desktop.display
    const open = ["/proc/net/tcp", "/proc/net/tcp6"].some((table) =>
      listeningPorts(readFileSync(table, "utf8")).has(port)
    )
    if (open)
      throw new Error(`TCP port ${port} is open, and the desktop must only listen on its socket`)
  }

  private stop(code: number): void {
    if (this.stopping) return

    this.stopping = true
    for (const child of this.children) child.kill("SIGTERM")
    const force = setTimeout(() => {
      for (const child of this.children) child.kill("SIGKILL")
    }, stopGraceMs)
    void Promise.all(this.children.map(exited)).then(() => {
      clearTimeout(force)
      rmSync(this.desktop.socket, { force: true })
      rmSync(this.desktop.xauthority, { force: true })
      this.ended?.(code)
    })
  }
}

const exited = (child: ChildProcess): Promise<void> =>
  new Promise((resolve) => {
    if (child.exitCode !== null || child.signalCode !== null || child.pid === undefined) resolve()
    else child.once("exit", () => resolve())
  })

const sleep = (ms: number): Promise<void> => new Promise((resolve) => setTimeout(resolve, ms))
