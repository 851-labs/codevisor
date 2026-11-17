import { type ChildProcess, spawn } from "node:child_process"
import { fileURLToPath } from "node:url"

export interface XcodeWindowStatus {
  readonly owned: boolean
}

export interface XcodeWindow {
  readonly opened: Promise<XcodeWindowStatus>
  readonly close: () => Promise<void>
}

const closeTimeoutMilliseconds = 30_000
const complaintGraceMilliseconds = 500

export function openXcodeWindow(projectPath: string, appPath: string): XcodeWindow {
  const child = spawn(
    "/usr/bin/osascript",
    [
      "-l",
      "JavaScript",
      fileURLToPath(new URL("./xcode-window-owner.jxa", import.meta.url)),
      projectPath,
      appPath
    ],
    { detached: true, stdio: ["pipe", "pipe", "pipe"] }
  )
  child.stdin?.on("error", () => {})
  const exited = exitOf(child)
  exited.catch(() => {})
  const opened = Promise.race([
    readinessOf(child),
    exited.then(() => {
      throw new Error("The Xcode window owner stopped before it found the window.")
    })
  ])
  let found = false
  opened.then(
    () => {
      found = true
    },
    () => {}
  )

  return {
    opened,
    close: async () => {
      const failure = await stopWithin(child, exited, closeTimeoutMilliseconds)
      if (found && failure !== undefined) throw failure
    }
  }
}

async function stopWithin(
  child: ChildProcess,
  exited: Promise<void>,
  timeout: number
): Promise<Error | undefined> {
  let abandoned = false
  const abandon = setTimeout(() => {
    abandoned = true
    child.kill("SIGKILL")
  }, timeout)
  child.stdin?.end()
  try {
    await exited
    return undefined
  } catch (error) {
    if (abandoned) return new Error("Xcode did not answer in time; the window may still be open.")
    return error instanceof Error ? error : new Error(String(error))
  } finally {
    clearTimeout(abandon)
  }
}

function exitOf(child: ChildProcess): Promise<void> {
  let complaint = ""
  child.stderr?.on("data", (data: Buffer) => {
    complaint += data.toString("utf8")
  })
  return new Promise<void>((resolve, reject) => {
    child.once("error", reject)
    child.once("exit", (code, signal) => {
      if (code === 0) return resolve()

      void complaintEnd(child).then(() => {
        reject(
          new Error(reasonIn(complaint) ?? `The Xcode window owner exited (${signal ?? code}).`)
        )
      })
    })
  })
}

function complaintEnd(child: ChildProcess): Promise<void> {
  return new Promise<void>((resolve) => {
    child.stderr?.once("end", resolve)
    setTimeout(resolve, complaintGraceMilliseconds)
  })
}

function readinessOf(child: ChildProcess): Promise<XcodeWindowStatus> {
  return new Promise<XcodeWindowStatus>((resolve, reject) => {
    let output = ""
    child.stdout?.on("data", (data: Buffer) => {
      output += data.toString("utf8")
      if (!output.includes("\n")) return
      try {
        const status: unknown = JSON.parse(output.slice(0, output.indexOf("\n")))
        if (!isReadyStatus(status))
          throw new Error("The Xcode window owner did not report readiness.")
        resolve({ owned: status.owned === true })
      } catch (error) {
        reject(error)
      }
    })
  })
}

function reasonIn(complaint: string): string | undefined {
  const reason = /execution error: (?:Error: )*(.*?)(?: \(-?\d+\))?\s*$/s.exec(complaint)?.[1]
  return reason === undefined || reason === "" ? undefined : reason
}

function isReadyStatus(value: unknown): value is { ready: true; owned?: unknown } {
  return value !== null && typeof value === "object" && "ready" in value && value.ready === true
}
