import { existsSync, mkdtempSync, rmSync, writeFileSync } from "node:fs"
import { homedir, tmpdir } from "node:os"
import { dirname, join } from "node:path"

import type { PrepareSpawn } from "./terminal-launch.js"
import { restoredSize } from "./terminal-snapshot.js"
import type {
  SavedResume,
  TerminalLaunch,
  TerminalProcess,
  TerminalSnapshotEntry,
  TerminalSpawnRequest
} from "./types.js"
import type { VtState } from "./vt/ghostty-vt.js"

export const restartPreamble = (screen: VtState): string => {
  if (screen.alternateScreen) return `${LEAVE_ALTERNATE_SCREEN}${DEFAULT_MODES}${CLEAR_SCREEN}`
  return `${DEFAULT_MODES}\r\n`
}

const LEAVE_ALTERNATE_SCREEN = "\u001b[?1049l"
const DEFAULT_MODES = [
  "\u001b[?1000l\u001b[?1002l\u001b[?1003l\u001b[?1006l",
  "\u001b[?1004l\u001b[?2004l",
  "\u001b[=0;1u",
  "\u001b[?25h\u001b[0m"
].join("")
const CLEAR_SCREEN = "\u001b[H\u001b[2J"

export interface RestartLaunch {
  readonly request: TerminalSpawnRequest
  readonly discard: () => void
}

export interface QueuedProcess extends TerminalProcess {
  readonly replayInto: (process: TerminalProcess) => void
}

export const restartableLaunch = (entry: TerminalSnapshotEntry): TerminalLaunch | undefined =>
  entry.closed || entry.external ? undefined : entry.launch

export const restartLaunchFor = (
  entry: TerminalSnapshotEntry,
  launch: TerminalLaunch,
  prepareSpawn: PrepareSpawn,
  userId: number | undefined
): RestartLaunch => {
  const restart = { entry, launch, prepareSpawn }
  return programRestart(restart, entry.resume, userId) ?? shellRestart(restart)
}

export const makeQueuedProcess = (): QueuedProcess => {
  const writes: Array<string> = []
  return {
    write: (data) => writes.push(data),
    resize: () => undefined,
    kill: () => undefined,
    replayInto: (process) => {
      for (const data of writes.splice(0)) process.write(data)
    }
  }
}

interface Restart {
  readonly entry: TerminalSnapshotEntry
  readonly launch: TerminalLaunch
  readonly prepareSpawn: PrepareSpawn
}

const programRestart = (
  restart: Restart,
  saved: SavedResume | undefined,
  userId: number | undefined
): RestartLaunch | undefined => {
  if (saved === undefined || saved.uid !== userId) return undefined

  const cwd = programDirectory(restart, saved)
  if (cwd === undefined) return undefined

  const file = writeResumeFile(cwd, saved.argv)
  const discard = (): void => rmSync(dirname(file), { recursive: true, force: true })
  const request = restart.prepareSpawn(restartRequest(restart, cwd), undefined, file)
  if (request.resumesProgram !== true) {
    discard()
    return undefined
  }
  return { request, discard }
}

const shellRestart = (restart: Restart): RestartLaunch => {
  const cwd = shellDirectory(restart)
  const request = restart.prepareSpawn(restartRequest(restart, cwd))
  return { request, discard: () => undefined }
}

const programDirectory = (restart: Restart, saved: SavedResume): string | undefined => {
  if (saved.cwd !== undefined && existsSync(saved.cwd)) return saved.cwd
  if (saved.cwdFromReport) return undefined
  return shellDirectory(restart)
}

const shellDirectory = ({ entry, launch }: Restart): string =>
  [entry.cwd, launch.cwd].find((cwd) => cwd !== undefined && existsSync(cwd)) ?? homedir()

const writeResumeFile = (cwd: string, argv: ReadonlyArray<string>): string => {
  const file = join(mkdtempSync(join(tmpdir(), "codevisor-resume-")), "command")
  writeFileSync(file, [cwd, ...argv].map((line) => `${line}\n`).join(""), { mode: 0o600 })
  return file
}

const restartRequest = ({ entry, launch }: Restart, cwd: string) => {
  const size = restoredSize(entry)
  return {
    sessionId: entry.sessionId,
    cwd,
    cols: size.cols,
    rows: size.rows,
    ...(launch.shell === undefined ? {} : { shell: launch.shell }),
    ...(launch.args === undefined ? {} : { args: launch.args })
  }
}
