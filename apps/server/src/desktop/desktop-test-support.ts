import type { PrivateSocket } from "../routes/private-socket.js"
import { type DesktopManager, makeDesktopManager } from "./desktop-manager.js"
import type { DesktopSystem, Ran } from "./desktop-system.js"

export interface FakeMachineOptions {
  readonly programs?: ReadonlyArray<string>
  readonly files?: Record<string, string>
  readonly folders?: Record<string, ReadonlyArray<string>>
  readonly existing?: ReadonlyArray<string>
  readonly results?: Record<string, Ran>
  readonly failing?: ReadonlyArray<string>
  readonly uid?: number
  readonly env?: Record<string, string | undefined>
  readonly socketAppearsAfterPolls?: number
  readonly socketVanishesAfterPolls?: number
  readonly alive?: ReadonlyArray<number>
  readonly holds?: { readonly prefix: string; readonly until: Promise<void> }
  readonly sessionNeverSettles?: boolean
}

export interface FakeMachine {
  readonly system: DesktopSystem
  readonly manager: DesktopManager
  readonly commands: string[]
  readonly files: Map<string, string>
  readonly spawned: Array<{ command: string; args: ReadonlyArray<string>; logPath: string }>
  readonly terminated: number[]
  readonly madePrivate: string[]
  readonly closedToOthers: string[]
  readonly changes: { count: number }
  readonly waits: { count: number }
}

export const DATA_DIR = "/home/codevisor/.codevisor/data"
export const LOGS_DIR = "/home/codevisor/.codevisor/logs"
export const CONFIG = `${DATA_DIR}/screen-sharing.json`
export const UNIT = "/home/codevisor/.config/systemd/user/codevisor-desktop.service"
export const RUNNER = {
  program: "/opt/codevisor/bin/node",
  args: ["/opt/codevisor/cli.js", "desktop", "run", "--data-dir", DATA_DIR]
}
export const EVERY_PROGRAM = [
  "Xvnc",
  "startxfce4",
  "xfconf-query",
  "dbus-run-session",
  "xclip",
  "python3",
  "apt-get",
  "sudo"
]
export const UBUNTU = {
  "/etc/os-release": 'PRETTY_NAME="Ubuntu 24.04.5 LTS"\nID=ubuntu\nID_LIKE=debian\n'
}

export const APT_UPDATE_LOOP = `for try in $(seq 60); do out=$(apt-get update -q 2>&1) && exit 0; echo "$out"; echo "$out" | grep -q "Could not get lock" || exit 1; sleep 10; done; exit 1`

export const TIME_LIMIT = "timeout --kill-after=30 1200"
export const AS_ROOT = `sudo -n ${TIME_LIMIT}`

export const SESSION_RUNNER = 4243

export const CHANGED = "(told that what is shared changed)"

const defaultEnv: Record<string, string | undefined> = { XDG_RUNTIME_DIR: "/run/user/1001" }
const ok: Ran = { code: 0, output: "" }
const failed: Ran = { code: 1, output: "" }
const programProbe = /^sh -c command -v "\$1" sh (.+)$/

export const recordedDesktop = (machine: Pick<FakeMachine, "files">) =>
  JSON.parse(machine.files.get(CONFIG) ?? "").displays.find(
    (entry: { id: string }) => entry.id === "desktop"
  )

export const settled = async (manager: DesktopManager) => {
  let status = await manager.status()
  while (status.busy !== undefined) status = await manager.status()
  return status
}

export const fakeMachine = (options: FakeMachineOptions = {}): FakeMachine => {
  const commands: string[] = []
  const files = new Map<string, string>(Object.entries(options.files ?? {}))
  const spawned: FakeMachine["spawned"] = []
  const terminated: number[] = []
  const madePrivate: string[] = []
  const closedToOthers: string[] = []
  const alive = new Set<number>(options.alive ?? [])
  const changes = { count: 0 }
  const waits = { count: 0 }
  const programs = new Set(options.programs ?? EVERY_PROGRAM)
  let polls = 0

  const answer = (line: string): Ran => {
    const probed = programProbe.exec(line)
    if (probed !== null) return programs.has(probed[1]!) ? ok : failed
    if (options.failing?.some((prefix) => line.startsWith(prefix)) === true) return failed

    return options.results?.[line] ?? ok
  }

  const socketIsUp = (): boolean => {
    const appearsAfter = options.socketAppearsAfterPolls ?? 0
    const vanishesAfter = options.socketVanishesAfterPolls ?? Number.POSITIVE_INFINITY
    return files.has(CONFIG) && polls > appearsAfter && polls <= vanishesAfter
  }
  const readyMark = (): string | undefined =>
    options.sessionNeverSettles !== true && socketIsUp() ? `${SESSION_RUNNER}\n` : undefined

  const system: DesktopSystem = {
    platform: "linux",
    uid: options.uid ?? 1001,
    account: "codevisor",
    home: "/home/codevisor",
    env: options.env ?? defaultEnv,
    run: async (command, args) => {
      const line = [command, ...args].join(" ")
      if (programProbe.exec(line) === null) commands.push(line)
      if (options.holds !== undefined && line.startsWith(options.holds.prefix))
        await options.holds.until
      return answer(line)
    },
    spawnDetached: (command, args, logPath) => {
      spawned.push({ command, args, logPath })
      alive.add(4242)
      files.set("/proc/4242/cmdline", [command, ...args].join("\0"))
      return 4242
    },
    processAlive: (pid) => pid === SESSION_RUNNER || alive.has(pid),
    terminate: (pid) => {
      terminated.push(pid)
      alive.delete(pid)
      files.delete(`/proc/${pid}/cmdline`)
    },
    readText: (path) => {
      if (path.endsWith(".ready")) return readyMark()
      if (path === `/proc/${SESSION_RUNNER}/cmdline`)
        return [RUNNER.program, ...RUNNER.args, ""].join("\0")

      return files.get(path)
    },
    writeText: (path, text) => void files.set(path, text),
    remove: (path) => void files.delete(path),
    exists: (path) =>
      files.has(path) ||
      path === (options.env ?? defaultEnv)["XDG_RUNTIME_DIR"] ||
      options.existing?.includes(path) === true ||
      options.folders?.[path] !== undefined,
    listFolder: (path) => options.folders?.[path] ?? [],
    makePrivateFolder: (path) => void madePrivate.push(path),
    closeToOtherAccounts: (path) => void closedToOthers.push(path),
    sleep: async () => {
      waits.count += 1
    }
  }

  const locate = (configured: string): PrivateSocket => {
    polls += 1
    if (socketIsUp()) return { path: configured }

    return { problem: "missing", detail: `nothing at ${configured}` }
  }

  const manager = makeDesktopManager({
    system,
    dataDir: DATA_DIR,
    logsDir: LOGS_DIR,
    runner: RUNNER,
    changed: () => {
      changes.count += 1
      commands.push(CHANGED)
    },
    locate
  })
  return {
    system,
    manager,
    commands,
    files,
    spawned,
    terminated,
    madePrivate,
    closedToOthers,
    changes,
    waits
  }
}
