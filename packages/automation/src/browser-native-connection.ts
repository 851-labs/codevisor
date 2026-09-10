import { EventEmitter } from "node:events"
import { readFileSync } from "node:fs"
import { createConnection, type Socket } from "node:net"
import { join } from "node:path"
import { CdpConnection } from "./browser-cdp.js"

export const nativeBrowserSocketPath = (dataDir: string, uid = process.getuid?.() ?? 0): string => {
  let hash = 2166136261
  for (const byte of Buffer.from(dataDir)) hash = Math.imul(hash ^ byte, 16777619) >>> 0
  return `/tmp/codevisor-browser-${uid}-${hash.toString(16)}.sock`
}

class NativeSocket extends EventEmitter {
  readyState = 1
  #buffer = ""
  constructor(readonly socket: Socket) {
    super()
    socket.setEncoding("utf8")
    socket.on("data", (data: string) => {
      this.#buffer += data
      if (this.#buffer.length > 64 * 1024 * 1024) {
        this.terminate()
        return
      }
      let newline: number
      while ((newline = this.#buffer.indexOf("\n")) >= 0) {
        const line = this.#buffer.slice(0, newline)
        this.#buffer = this.#buffer.slice(newline + 1)
        this.emit("message", Buffer.from(line))
      }
    })
    socket.on("error", (error) => this.emit("error", error))
    socket.on("close", () => {
      this.readyState = 3
      this.emit("close")
    })
  }
  send(message: string): void {
    this.socket.write(message + "\n")
  }
  close(): void {
    this.socket.end()
  }
  terminate(): void {
    this.socket.destroy()
  }
}

export const connectNativeBrowser = async (
  dataDir: string,
  sessionId: string,
  platform: string = process.platform
): Promise<
  { connection: CdpConnection; reason?: never } | { connection?: never; reason: string }
> => {
  if (platform !== "darwin") return { reason: "The built-in browser requires a local macOS app." }
  let token: string
  try {
    token = readFileSync(join(dataDir, "browser-use-token"), "utf8")
  } catch {
    return { reason: "The local Codevisor app has not initialized browser automation." }
  }
  let connection: CdpConnection | undefined
  let reason = "This session is not open in the Codevisor app on the server machine."
  try {
    const socket = await new Promise<Socket>((resolve, reject) => {
      const socket = createConnection(nativeBrowserSocketPath(dataDir))
      const timer = setTimeout(() => {
        socket.destroy()
        reject(new Error("Native browser connection timed out"))
      }, 1500)
      socket.once("error", (error) => {
        clearTimeout(timer)
        reject(error)
      })
      socket.once("connect", () => {
        clearTimeout(timer)
        resolve(socket)
      })
    })
    connection = CdpConnection.fromSocket(new NativeSocket(socket))
    const result = await connection.send<{ available: boolean }>(
      "Codevisor.connect",
      { token, sessionId },
      undefined,
      1500
    )
    if (result.available) return { connection }
  } catch (cause) {
    reason = /timed out/i.test(String(cause))
      ? "The local Codevisor app did not respond. Check that machine for a blocking dialog."
      : "The local Codevisor browser connection is unavailable."
  }
  await connection?.close()
  return { reason }
}
