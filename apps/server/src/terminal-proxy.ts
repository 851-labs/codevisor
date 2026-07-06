#!/usr/bin/env node
import type { TerminalClientFrame, TerminalCreateResponse, TerminalServerFrame } from "@herdman/api"
import { randomUUID } from "node:crypto"
import { setTimeout as sleep } from "node:timers/promises"
import { WebSocket } from "ws"

interface ProxyOptions {
  readonly server: string
  readonly sessionId: string
  readonly cwd: string
  readonly shell?: string
  readonly clientId: string
  /// Bearer token for servers that require auth (remote machines; same-machine
  /// connections are exempt server-side).
  readonly token?: string
  /// Attach to an agent-owned terminal instead of spawning a shell: creation
  /// retries until the terminal is registered, and pane teardown must NOT
  /// close the terminal (the process lifecycle belongs to the agent).
  readonly attachOnly: boolean
}

type TerminalClientFramePayload =
  | { readonly type: "input"; readonly data: string }
  | { readonly type: "resize"; readonly cols: number; readonly rows: number }
  | { readonly type: "close" }

const parseArgs = (args: ReadonlyArray<string>): ProxyOptions => {
  const parsed = new Map<string, string>()
  for (let index = 0; index < args.length; index += 1) {
    const arg = args[index]
    if (arg?.startsWith("--") === true) {
      parsed.set(arg.slice(2), args[index + 1] ?? "")
      index += 1
    }
  }

  const server = parsed.get("server")
  const sessionId = parsed.get("session-id")
  const cwd = parsed.get("cwd")
  if (server === undefined || server.length === 0) {
    throw new Error("Missing --server")
  }
  if (sessionId === undefined || sessionId.length === 0) {
    throw new Error("Missing --session-id")
  }
  if (cwd === undefined || cwd.length === 0) {
    throw new Error("Missing --cwd")
  }
  const shell = optionalArg(parsed.get("shell"))
  const token = optionalArg(parsed.get("token"))
  let options: ProxyOptions = {
    server,
    sessionId,
    cwd,
    clientId: optionalArg(parsed.get("client-id")) ?? randomUUID(),
    attachOnly: parsed.get("attach-only") === "true"
  }
  if (shell !== undefined) {
    options = { ...options, shell }
  }
  if (token !== undefined) {
    options = { ...options, token }
  }
  return options
}

const authHeaders = (options: ProxyOptions): Record<string, string> =>
  options.token === undefined ? {} : { Authorization: `Bearer ${options.token}` }

const optionalArg = (value: string | undefined): string | undefined =>
  value === undefined || value.length === 0 ? undefined : value

const terminalSize = (): { readonly cols: number; readonly rows: number } => ({
  cols: process.stdout.columns ?? 80,
  rows: process.stdout.rows ?? 24
})

const createTerminal = async (options: ProxyOptions): Promise<TerminalCreateResponse> => {
  const size = terminalSize()
  const body = {
    sessionId: options.sessionId,
    cwd: options.cwd,
    cols: size.cols,
    rows: size.rows,
    ...(options.shell === undefined ? {} : { shell: options.shell }),
    ...(options.attachOnly ? { attachOnly: true } : {})
  }
  const response = await fetch(urlFor(options.server, "/v1/terminals"), {
    body: JSON.stringify(body),
    headers: {
      Accept: "application/json",
      "Content-Type": "application/json",
      ...authHeaders(options)
    },
    method: "POST"
  })
  if (!response.ok) {
    throw new Error(`Terminal create failed: HTTP ${response.status}`)
  }
  return (await response.json()) as TerminalCreateResponse
}

const main = async (): Promise<void> => {
  const options = parseArgs(process.argv.slice(2))
  const clientId = options.clientId
  let clientSeq = 0
  let lastOutputSeq = 0
  let socket: WebSocket | undefined
  let exited = false
  const pendingFrames: Array<TerminalClientFrame> = []

  if (process.stdin.isTTY) {
    process.stdin.setRawMode(true)
  }
  process.stdin.resume()

  const enqueue = (payload: TerminalClientFramePayload): void => {
    clientSeq += 1
    const frame = clientFrame(payload, clientId, clientSeq)
    if (socket?.readyState === WebSocket.OPEN) {
      socket.send(JSON.stringify(frame))
    } else {
      pendingFrames.push(frame)
    }
  }

  process.stdin.on("data", (chunk: Buffer) => {
    enqueue({ type: "input", data: chunk.toString("utf8") })
  })

  process.on("SIGWINCH", () => {
    const size = terminalSize()
    enqueue({ type: "resize", cols: size.cols, rows: size.rows })
  })

  process.on("SIGTERM", () => {
    // Attach-only proxies are viewers: tearing down the pane must not kill
    // the agent-owned process behind the terminal.
    if (!options.attachOnly) {
      enqueue({ type: "close" })
    }
    exited = true
    socket?.close()
  })

  while (!exited) {
    try {
      const activeTerminal = await createTerminal(options)
      await new Promise<void>((resolve) => {
        const websocketUrl = websocketUrlFor(
          options.server,
          activeTerminal.websocketPath,
          lastOutputSeq
        )
        const nextSocket = new WebSocket(websocketUrl, { headers: authHeaders(options) })
        socket = nextSocket
        nextSocket.on("open", () => {
          while (pendingFrames.length > 0 && nextSocket.readyState === WebSocket.OPEN) {
            const frame = pendingFrames.shift()
            if (frame !== undefined) {
              nextSocket.send(JSON.stringify(frame))
            }
          }
          const size = terminalSize()
          enqueue({ type: "resize", cols: size.cols, rows: size.rows })
        })
        nextSocket.on("message", (data) => {
          const frame = JSON.parse(data.toString()) as TerminalServerFrame
          if (frame.seq > lastOutputSeq) {
            lastOutputSeq = frame.seq
          }
          switch (frame.type) {
            case "output": {
              process.stdout.write(frame.data)
              break
            }
            case "exit": {
              exited = true
              nextSocket.close()
              process.exitCode = frame.exitCode ?? 0
              resolve()
              break
            }
            case "error": {
              process.stderr.write(`${frame.message}\n`)
              break
            }
          }
        })
        nextSocket.on("close", resolve)
        nextSocket.on("error", (error) => {
          process.stderr.write(`${error.message}\n`)
          nextSocket.close()
        })
      })
    } catch (cause) {
      process.stderr.write(`${cause instanceof Error ? cause.message : String(cause)}\n`)
    }

    if (!exited) {
      await sleep(750)
    }
  }
}

const urlFor = (server: string, path: string): string => {
  const trimmed = server.replace(/\/+$/, "")
  return `${trimmed}${path}`
}

const websocketUrlFor = (server: string, path: string, lastOutputSeq: number): string => {
  const httpUrl = new URL(urlFor(server, path))
  httpUrl.searchParams.set("lastOutputSeq", String(lastOutputSeq))
  httpUrl.protocol = httpUrl.protocol === "https:" ? "wss:" : "ws:"
  return httpUrl.toString()
}

const clientFrame = (
  payload: TerminalClientFramePayload,
  clientId: string,
  clientSeq: number
): TerminalClientFrame => {
  switch (payload.type) {
    case "input": {
      return { type: "input", clientId, clientSeq, data: payload.data }
    }
    case "resize": {
      return {
        type: "resize",
        clientId,
        clientSeq,
        cols: payload.cols,
        rows: payload.rows
      }
    }
    case "close": {
      return { type: "close", clientId, clientSeq }
    }
  }
}

main().catch((cause: unknown) => {
  process.stderr.write(`${cause instanceof Error ? cause.message : String(cause)}\n`)
  process.exitCode = 1
})
