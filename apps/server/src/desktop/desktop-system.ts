import { execFile, spawn } from "node:child_process"
import {
  chmodSync,
  closeSync,
  existsSync,
  mkdirSync,
  openSync,
  readdirSync,
  readFileSync,
  rmSync,
  statSync,
  writeFileSync
} from "node:fs"
import { homedir, userInfo } from "node:os"
import { dirname } from "node:path"

export interface Ran {
  readonly code: number
  readonly output: string
}

export interface DesktopSystem {
  readonly platform: NodeJS.Platform
  readonly uid: number
  readonly account: string
  readonly home: string
  readonly env: Readonly<Record<string, string | undefined>>
  readonly run: (command: string, args: ReadonlyArray<string>, timeoutMs?: number) => Promise<Ran>
  readonly spawnDetached: (
    command: string,
    args: ReadonlyArray<string>,
    logPath: string
  ) => number | undefined
  readonly processAlive: (pid: number) => boolean
  readonly terminate: (pid: number) => void
  readonly readText: (path: string) => string | undefined
  readonly writeText: (path: string, text: string) => void
  readonly remove: (path: string) => void
  readonly exists: (path: string) => boolean
  readonly listFolder: (path: string) => ReadonlyArray<string>
  readonly makePrivateFolder: (path: string) => void
  readonly closeToOtherAccounts: (path: string) => void
  readonly sleep: (ms: number) => Promise<void>
}

const commandNotFound = 127
const defaultTimeoutMs = 20_000
const outputLimitBytes = 8 * 1024 * 1024
const ownerOnly = 0o700
const permissionBits = 0o7777
const othersMayWrite = 0o022

export const systemDesktopSystem = (): DesktopSystem => ({
  platform: process.platform,
  uid: process.getuid?.() ?? -1,
  account: userInfo().username,
  home: homedir(),
  env: process.env,
  run: (command, args, timeoutMs = defaultTimeoutMs) =>
    new Promise((resolve) => {
      execFile(
        command,
        [...args],
        { encoding: "utf8", timeout: timeoutMs, maxBuffer: outputLimitBytes },
        (error, stdout, stderr) => {
          const code = error === null ? 0 : exitCodeOf(error.code)
          resolve({ code, output: `${stdout}${stderr}` })
        }
      )
    }),
  spawnDetached: (command, args, logPath) => {
    mkdirSync(dirname(logPath), { recursive: true })
    const log = openSync(logPath, "a")
    const child = spawn(command, [...args], { detached: true, stdio: ["ignore", log, log] })
    closeSync(log)
    child.once("error", () => undefined)
    child.unref()
    return child.pid
  },
  processAlive,
  terminate: (pid) => {
    try {
      process.kill(pid, "SIGTERM")
    } catch {
      return
    }
  },
  readText: (path) => {
    try {
      return readFileSync(path, "utf8")
    } catch {
      return undefined
    }
  },
  writeText: (path, text) => {
    mkdirSync(dirname(path), { recursive: true })
    writeFileSync(path, text, "utf8")
  },
  remove: (path) => rmSync(path, { force: true }),
  exists: existsSync,
  listFolder: (path) => {
    try {
      return readdirSync(path)
    } catch {
      return []
    }
  },
  makePrivateFolder: (path) => {
    try {
      mkdirSync(path, { recursive: true, mode: ownerOnly })
      chmodSync(path, ownerOnly)
    } catch {
      return
    }
  },
  closeToOtherAccounts: (path) => {
    try {
      const entry = statSync(path)
      if (entry.uid !== process.getuid?.()) return

      chmodSync(path, entry.mode & permissionBits & ~othersMayWrite)
    } catch {
      return
    }
  },
  sleep: (ms) => new Promise((resolve) => setTimeout(resolve, ms))
})

const exitCodeOf = (code: unknown): number => (typeof code === "number" ? code : commandNotFound)

export const processAlive = (pid: number): boolean => {
  try {
    process.kill(pid, 0)
    return true
  } catch (error) {
    return error instanceof Error && "code" in error && error.code === "EPERM"
  }
}
