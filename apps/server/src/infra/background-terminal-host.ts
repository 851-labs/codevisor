import { unlinkSync } from "node:fs"
/// Unix-socket host for out-of-process background commands (see bg-wrap.ts).
///
/// A wrapper process connects, introduces itself with a `hello` frame naming
/// its terminal key, then streams `output`/`exit` frames; the host registers
/// the process as an external terminal and forwards terminal input/kill
/// back down the socket. One connection == one background process.
import { createServer, type Server, type Socket } from "node:net"
import { join } from "node:path"

import { trackProcessTree } from "@codevisor/processes"

/// Structural match for the agent-runtime's BackgroundTerminalRegistry —
/// declared locally so this module stays importable without the runtime.
export interface BackgroundTerminalHostRegistry {
  readonly register: (
    key: string,
    controls: {
      readonly write?: (data: string) => void
      readonly kill?: () => void
      readonly stop?: () => Promise<void>
    }
  ) => {
    readonly output: (data: string) => void
    readonly exit: (exitCode?: number) => void
    readonly remove: () => void
  }
}

/// Unix socket paths are bounded by `sun_path`: 104 bytes on macOS and the
/// BSDs (terminator included), 108 on Linux. 103 usable bytes is the budget
/// that fits everywhere the server runs.
export const UNIX_SOCKET_PATH_BUDGET = 103

/// Where the background-command socket lives. Prefer `tmpDir` (normally
/// TMPDIR, which the dev runner points inside the worktree to keep instances
/// isolated) when the result fits the budget; otherwise fall back to the
/// system-wide `fallbackDir`, the same escape hatch tmux and ssh use, since
/// the pid already keeps the file name unique.
export const backgroundTerminalSocketPath = (
  tmpDir: string,
  pid: number,
  fallbackDir = "/tmp"
): string => {
  const name = `codevisor-bg-${pid}.sock`
  const preferred = join(tmpDir, name)
  return Buffer.byteLength(preferred) <= UNIX_SOCKET_PATH_BUDGET
    ? preferred
    : join(fallbackDir, name)
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
  readonly pid?: number
}

export const startBackgroundTerminalHost = (options: {
  readonly socketPath: string
  readonly registry: BackgroundTerminalHostRegistry
  readonly trackProcess?: typeof trackProcessTree
}): Promise<BackgroundTerminalHost> => {
  const server: Server = createServer((socket) =>
    handleConnection(socket, options.registry, options.trackProcess ?? trackProcessTree)
  )
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

const handleConnection = (
  socket: Socket,
  registry: BackgroundTerminalHostRegistry,
  track: typeof trackProcessTree
): void => {
  let stream: { output: (data: string) => void; exit: (exitCode?: number) => void } | undefined
  let exited = false
  let buffered = ""
  let tracked: ReturnType<typeof trackProcessTree> | undefined

  const handleFrame = (frame: WrapperFrame): void => {
    switch (frame.type) {
      case "hello": {
        if (stream !== undefined || typeof frame.key !== "string") break
        const tree = typeof frame.pid === "number" && frame.pid > 1 ? track(frame.pid) : undefined
        tracked = tree
        tree?.catch(() => undefined)
        stream = registry.register(frame.key, {
          write: (data) => {
            socket.write(`${JSON.stringify({ type: "input", data })}\n`)
          },
          kill: () => {
            socket.write(`${JSON.stringify({ type: "kill" })}\n`)
          },
          ...(tree === undefined
            ? {}
            : {
                stop: async () => {
                  await (await tree).stop()
                }
              })
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
    void tracked?.then((tree) => tree.stop()).catch(() => undefined)
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
