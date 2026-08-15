/// Unix-socket host for out-of-process background commands (see bg-wrap.ts).
///
/// A wrapper process connects, introduces itself with a `hello` frame naming
/// its terminal key, then streams `output`/`exit` frames; the host registers
/// the process as an external terminal and forwards terminal input/kill
/// back down the socket. One connection == one background process.
import { createServer, type Server, type Socket } from "node:net"
import { unlinkSync } from "node:fs"

/// Structural match for the agent-runtime's BackgroundTerminalRegistry —
/// declared locally so this module stays importable without the runtime.
export interface BackgroundTerminalHostRegistry {
  readonly register: (
    key: string,
    controls: {
      readonly write?: (data: string) => void
      readonly kill?: () => void
    }
  ) => {
    readonly output: (data: string) => void
    readonly exit: (exitCode?: number) => void
    readonly remove: () => void
  }
}

export interface BackgroundTerminalHost {
  readonly socketPath: string
  readonly close: () => void
}

interface WrapperFrame {
  readonly type?: string
  readonly key?: string
  readonly data?: string
  readonly exitCode?: number
}

export const startBackgroundTerminalHost = (options: {
  readonly socketPath: string
  readonly registry: BackgroundTerminalHostRegistry
}): Promise<BackgroundTerminalHost> => {
  const server: Server = createServer((socket) => handleConnection(socket, options.registry))
  // A previous server process may have left its socket file behind.
  try {
    unlinkSync(options.socketPath)
  } catch {
    // Nothing stale to remove.
  }
  return new Promise((resolvePromise, rejectPromise) => {
    server.once("error", rejectPromise)
    server.listen(options.socketPath, () => {
      server.removeListener("error", rejectPromise)
      resolvePromise({
        socketPath: options.socketPath,
        close: () => {
          server.close()
          try {
            unlinkSync(options.socketPath)
          } catch {
            // Already gone.
          }
        }
      })
    })
  })
}

const handleConnection = (socket: Socket, registry: BackgroundTerminalHostRegistry): void => {
  let stream: { output: (data: string) => void; exit: (exitCode?: number) => void } | undefined
  let exited = false
  let buffered = ""

  const handleFrame = (frame: WrapperFrame): void => {
    switch (frame.type) {
      case "hello": {
        if (stream !== undefined || typeof frame.key !== "string") break
        stream = registry.register(frame.key, {
          write: (data) => {
            socket.write(`${JSON.stringify({ type: "input", data })}\n`)
          },
          kill: () => {
            socket.write(`${JSON.stringify({ type: "kill" })}\n`)
          }
        })
        break
      }
      case "output": {
        if (typeof frame.data === "string") {
          stream?.output(frame.data)
        }
        break
      }
      case "exit": {
        exited = true
        stream?.exit(typeof frame.exitCode === "number" ? frame.exitCode : undefined)
        break
      }
      default:
        break
    }
  }

  socket.on("data", (chunk: Buffer) => {
    buffered += chunk.toString("utf8")
    let newline = buffered.indexOf("\n")
    while (newline !== -1) {
      const line = buffered.slice(0, newline)
      buffered = buffered.slice(newline + 1)
      newline = buffered.indexOf("\n")
      if (line.trim().length === 0) continue
      try {
        handleFrame(JSON.parse(line) as WrapperFrame)
      } catch {
        // Malformed frame from a wrapper: skip it, keep the stream alive.
      }
    }
  })
  const settle = (): void => {
    // A wrapper dying without an exit frame (SIGKILL, crash) still ends the
    // terminal stream.
    if (!exited) {
      exited = true
      stream?.exit(undefined)
    }
  }
  socket.on("close", settle)
  socket.on("error", settle)
}

/// Shell-quotes one argv token with single quotes.
export const shellQuote = (value: string): string => `'${value.replaceAll("'", "'\\''")}'`

/// Builds the rewritten background command: the original command runs under
/// bg-wrap, teeing output to the host socket while stdout/stderr pass through.
export const wrapBackgroundCommand = (options: {
  readonly nodePath: string
  readonly wrapperPath: string
  readonly socketPath: string
}): ((key: string, command: string) => string) => {
  return (key, command) =>
    [
      shellQuote(options.nodePath),
      shellQuote(options.wrapperPath),
      shellQuote(options.socketPath),
      shellQuote(key),
      Buffer.from(command, "utf8").toString("base64")
    ].join(" ")
}
