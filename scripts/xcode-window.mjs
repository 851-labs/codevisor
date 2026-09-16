import { spawn } from "node:child_process"
import { fileURLToPath } from "node:url"

export async function openOwnedXcodeWindow(projectPath, appPath) {
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
  child.stdin.on("error", () => {})
  const exited = new Promise((resolve, reject) => {
    child.once("error", reject)
    child.once("exit", (code, signal) => {
      if (code === 0) resolve()
      else reject(new Error(`Xcode window owner exited (${signal ?? code}).`))
    })
  })
  // Attach immediately: startup and shutdown can both observe this rejection.
  exited.catch(() => {})
  const close = async () => {
    child.stdin.end()
    await exited
  }
  try {
    const ready = new Promise((resolve, reject) => {
      let output = ""
      child.stdout.on("data", (data) => {
        output += data
        if (!output.includes("\n")) return
        try {
          const status = JSON.parse(output.slice(0, output.indexOf("\n")))
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
    return { ...status, close, exited }
  } catch (error) {
    await close().catch(() => {})
    throw error
  }
}
