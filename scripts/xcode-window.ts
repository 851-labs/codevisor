import { spawn } from "node:child_process"
import { fileURLToPath } from "node:url"

export interface OwnedXcodeWindow {
  ready: boolean
  close: () => Promise<void>
  exited: Promise<void>
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
    { detached: true, stdio: ["pipe", "pipe", "inherit"] }
  )
  child.stdin?.on("error", () => {})
  const exited = new Promise<void>((resolve, reject) => {
    child.once("error", reject)
    child.once("exit", (code, signal) => {
      if (code === 0) resolve()
      else reject(new Error(`Xcode window owner exited (${signal ?? code}).`))
    })
  })
  // Attach immediately: startup and shutdown can both observe this rejection.
  exited.catch(() => {})
  const close = async () => {
    child.stdin?.end()
    await exited
  }
  try {
    const ready = new Promise<Record<string, unknown>>((resolve, reject) => {
      let output = ""
      child.stdout?.on("data", (data: Buffer) => {
        output += data
        if (!output.includes("\n")) return
        try {
          const status = JSON.parse(output.slice(0, output.indexOf("\n"))) as Record<
            string,
            unknown
          >
          if (!status.ready) throw new Error("Xcode window owner did not report readiness.")
          resolve(status)
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
    return { ...status, close, exited } as OwnedXcodeWindow
  } catch (error) {
    await close().catch(() => {})
    throw error
  }
}
