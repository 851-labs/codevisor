#!/usr/bin/env node
/// Background-shell wrapper: runs an agent's backgrounded command while
/// teeing its output to the server's background-terminal host over a unix
/// socket (NDJSON frames), so clients can attach to the live process as a
/// terminal tab.
///
///   bg-wrap.js <socketPath> <terminalKey> <base64Command>
///
/// The command's stdout/stderr still flow through this process's own
/// stdout/stderr unchanged — the agent harness (Claude Code's BashOutput)
/// keeps observing output exactly as if the command ran bare. The socket is
/// best-effort: if the server is unreachable the command still runs, it just
/// has no attachable mirror. Frames from the host carry terminal input
/// (forwarded to the child's stdin) and kill requests.
import { spawn } from "node:child_process"
import { connect } from "node:net"

interface HostFrame {
  readonly type: "input" | "resize" | "kill"
  readonly data?: string
}

const main = (): void => {
  const [socketPath, terminalKey, encodedCommand] = process.argv.slice(2)
  if (socketPath === undefined || terminalKey === undefined || encodedCommand === undefined) {
    process.stderr.write("usage: bg-wrap <socketPath> <terminalKey> <base64Command>\n")
    process.exit(2)
  }
  const command = Buffer.from(encodedCommand, "base64").toString("utf8")

  const child = spawn("/bin/sh", ["-c", command], {
    stdio: ["pipe", "pipe", "pipe"],
    env: process.env
  })

  let socketReady = false
  let socketDead = false
  const pending: Array<string> = []
  const socket = connect(socketPath)
  const send = (frame: Record<string, unknown>): void => {
    if (socketDead) return
    const line = `${JSON.stringify(frame)}\n`
    if (socketReady) {
      socket.write(line)
    } else if (pending.length < 4096) {
      pending.push(line)
    }
  }
  socket.on("connect", () => {
    socket.write(`${JSON.stringify({ type: "hello", key: terminalKey, command })}\n`)
    socketReady = true
    for (const line of pending.splice(0)) {
      socket.write(line)
    }
  })
  socket.on("error", () => {
    // Best-effort mirror: the command keeps running without it.
    socketReady = false
    socketDead = true
    pending.length = 0
  })

  let buffered = ""
  socket.on("data", (chunk: Buffer) => {
    buffered += chunk.toString("utf8")
    let newline = buffered.indexOf("\n")
    while (newline !== -1) {
      const line = buffered.slice(0, newline)
      buffered = buffered.slice(newline + 1)
      newline = buffered.indexOf("\n")
      if (line.trim().length === 0) continue
      let frame: HostFrame
      try {
        frame = JSON.parse(line) as HostFrame
      } catch {
        continue
      }
      switch (frame.type) {
        case "input":
          if (typeof frame.data === "string") {
            child.stdin.write(frame.data)
          }
          break
        case "kill":
          child.kill("SIGTERM")
          break
        default:
          // resize is meaningless without a PTY.
          break
      }
    }
  })

  child.stdout.on("data", (chunk: Buffer) => {
    process.stdout.write(chunk)
    send({ type: "output", data: chunk.toString("utf8") })
  })
  child.stderr.on("data", (chunk: Buffer) => {
    process.stderr.write(chunk)
    send({ type: "output", data: chunk.toString("utf8") })
  })

  const forward = (signal: NodeJS.Signals): void => {
    process.on(signal, () => {
      child.kill(signal)
    })
  }
  forward("SIGTERM")
  forward("SIGINT")
  forward("SIGHUP")

  child.once("exit", (code, signal) => {
    const exitCode = code ?? (signal === null ? 0 : 1)
    process.exitCode = exitCode
    send({ type: "exit", exitCode })
    socket.end()
    // Flush window for the final socket frames; unref'd so an already-dead
    // socket lets the process exit naturally.
    setTimeout(() => process.exit(exitCode), 150).unref()
    socket.once("close", () => process.exit(exitCode))
  })
}

main()
