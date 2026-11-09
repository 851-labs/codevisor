import { spawn } from "node:child_process"
import { fileURLToPath } from "node:url"

export interface OwnedXcodeWindow {
  readonly ready: true
  readonly owned: boolean
  readonly close: () => Promise<void>
  readonly exited: Promise<void>
}

export async function openOwnedXcodeWindow(
  projectPath: string,
  appPath: string
): Promise<OwnedXcodeWindow> {
  const child = spawn(
    "/usr/bin/osascript",
    [
      "-l",
      "JavaScript",
      fileURLToPath(new URL("./xcode-window-owner.jxa", import.meta.url)),
      projectPath,
      appPath
    ],
    {
      detached: true,
      stdio: ["pipe", "pipe", "inherit"]
    }
  )
  child.stdin.on("error", () => {})
  const exited = new Promise<void>((resolve, reject) => {
    child.once("error", reject)
    child.once("exit", (code, signal) => {
      if (code === 0) resolve()
      else reject(new Error(`Xcode window owner exited (${signal ?? code}).`))
    })
  })
  exited.catch(() => {})
  const close = async (): Promise<void> => {
    child.stdin.end()
    await exited
  }

  try {
    const ready = new Promise<{ owned: boolean }>((resolve, reject) => {
      let output = ""
      child.stdout.on("data", (data: Buffer) => {
        output += data.toString("utf8")
        if (!output.includes("\n")) return
        try {
          const status: unknown = JSON.parse(output.slice(0, output.indexOf("\n")))
          if (!isReadyStatus(status))
            throw new Error("Xcode window owner did not report readiness.")
          resolve({ owned: status.owned === true })
        } catch (error) {
          reject(error)
        }
      })
    })
    const status = await Promise.race([
      ready,
      exited.then(() => {
        throw new Error("Xcode window owner stopped before readiness.")
      })
    ])
    return { ready: true, owned: status.owned, close, exited }
  } catch (error) {
    await close().catch(() => {})
    throw error
  }
}

function isReadyStatus(value: unknown): value is { ready: true; owned?: unknown } {
  return value !== null && typeof value === "object" && "ready" in value && value.ready === true
}
