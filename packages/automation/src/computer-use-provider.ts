import type { CallToolResult } from "@modelcontextprotocol/sdk/types.js"
import { randomUUID } from "node:crypto"
import { existsSync, readFileSync } from "node:fs"
import { createConnection, type Socket } from "node:net"
import { join } from "node:path"
import { spawn, spawnSync, type ChildProcessWithoutNullStreams } from "node:child_process"
import type { AutomationToolProvider } from "./automation-provider.js"
import { textToolResult } from "./automation-provider.js"
import { findServerResource, type ServerResourceOptions } from "./server-resources.js"

import { computerUseTools } from "./computer-use-tools.js"

export { computerUseTools } from "./computer-use-tools.js"
interface PendingRequest {
  readonly resolve: (value: CallToolResult) => void
  readonly reject: (cause: Error) => void
  readonly timer: ReturnType<typeof setTimeout>
}

interface HelperClient {
  readonly request: (payload: Readonly<Record<string, unknown>>) => Promise<CallToolResult>
  readonly close: () => Promise<void>
  readonly isClosed: () => boolean
}

const jsonLineClient = (
  write: (line: string) => void,
  closeTransport: () => Promise<void>,
  subscribe: (onData: (data: Buffer) => void, onClose: (cause?: Error) => void) => void
): HelperClient => {
  const pending = new Map<string, PendingRequest>()
  let buffer = ""
  let closed: Error | undefined
  const failAll = (cause = new Error("Computer Use helper closed")) => {
    closed = cause
    for (const request of pending.values()) {
      clearTimeout(request.timer)
      request.reject(cause)
    }
    pending.clear()
  }
  subscribe((data) => {
    buffer += data.toString("utf8")
    while (true) {
      const newline = buffer.indexOf("\n")
      if (newline < 0) break
      const line = buffer.slice(0, newline)
      buffer = buffer.slice(newline + 1)
      if (line.trim().length === 0) continue
      try {
        const message = JSON.parse(line) as { id?: unknown; result?: unknown; error?: unknown }
        if (typeof message.id !== "string") continue
        const request = pending.get(message.id)
        if (request === undefined) continue
        pending.delete(message.id)
        clearTimeout(request.timer)
        if (typeof message.error === "string") request.reject(new Error(message.error))
        else request.resolve(message.result as CallToolResult)
      } catch {
        // A malformed helper response is ignored; the request remains pending
        // until the transport closes and reports a useful failure.
      }
    }
  }, failAll)
  return {
    request: (payload) => {
      if (closed !== undefined) return Promise.reject(closed)
      const id = randomUUID()
      return new Promise<CallToolResult>((resolve, reject) => {
        const timer = setTimeout(() => {
          pending.delete(id)
          reject(new Error("Computer Use helper timed out"))
        }, 30_000)
        timer.unref?.()
        pending.set(id, { resolve, reject, timer })
        write(`${JSON.stringify({ id, ...payload })}\n`)
      })
    },
    close: async () => {
      failAll()
      await closeTransport()
    },
    isClosed: () => closed !== undefined
  }
}

const stablePathHash = (value: string): string => {
  let hash = 2_166_136_261
  for (const byte of Buffer.from(value)) {
    hash ^= byte
    hash = Math.imul(hash, 16_777_619) >>> 0
  }
  return hash.toString(16)
}

// Keep this in sync with ComputerUseBridge.socketPath in the native app.
// Foundation and Node can resolve different temporary directories, and a
// worktree's TMPDIR can exceed macOS's 103-byte Unix socket path limit.
export const macComputerUseSocketPath = (
  dataDir: string,
  userId = process.getuid?.() ?? 0
): string => `/tmp/codevisor-cu-${userId}-${stablePathHash(dataDir)}.sock`

const macBridgeConfiguration = (
  dataDir: string
): { readonly socketPath: string; readonly token: string } | undefined => {
  const envSocketPath = process.env.CODEVISOR_COMPUTER_USE_SOCKET
  const envToken = process.env.CODEVISOR_COMPUTER_USE_TOKEN
  if (envSocketPath !== undefined && envToken !== undefined) {
    return { socketPath: envSocketPath, token: envToken }
  }
  const socketPath = macComputerUseSocketPath(dataDir)
  const tokenPath = join(dataDir, "computer-use-token")
  if (!existsSync(socketPath) || !existsSync(tokenPath)) return undefined
  try {
    const token = readFileSync(tokenPath, "utf8").trim()
    return token.length === 0 ? undefined : { socketPath, token }
  } catch {
    return undefined
  }
}

const connectMacHelper = async (dataDir: string): Promise<HelperClient> => {
  const configuration = macBridgeConfiguration(dataDir)
  if (configuration === undefined) {
    throw new Error("Computer Use requires the native Codevisor app on macOS")
  }
  const { socketPath, token } = configuration
  const socket = await new Promise<Socket>((resolve, reject) => {
    const connection = createConnection(socketPath)
    connection.once("connect", () => resolve(connection))
    connection.once("error", reject)
  })
  const client = jsonLineClient(
    (line) => socket.write(line),
    async () => {
      socket.end()
      socket.destroy()
    },
    (onData, onClose) => {
      socket.on("data", onData)
      socket.once("close", () => onClose())
      socket.once("error", onClose)
    }
  )
  await client.request({ type: "authenticate", token })
  return client
}

export const linuxComputerUseHelperPath = (
  options: ServerResourceOptions = {}
): string | undefined => findServerResource("computer-use-linux.py", options)

const linuxHelperStatus = (): { readonly available: boolean; readonly detail?: string } => {
  if (linuxComputerUseHelperPath() === undefined) {
    return { available: false, detail: "The Linux Computer Use helper is not installed" }
  }
  const probe = spawnSync(
    "python3",
    ["-c", "import gi; gi.require_version('Atspi', '2.0'); from gi.repository import Atspi"],
    { encoding: "utf8", timeout: 5_000 }
  )
  if (probe.status === 0) return { available: true }
  return {
    available: false,
    detail:
      "Computer Use requires Ubuntu accessibility packages. Install python3-gi, " +
      "gir1.2-atspi-2.0, and gir1.2-gtk-3.0."
  }
}

const connectLinuxHelper = async (): Promise<HelperClient> => {
  const script = linuxComputerUseHelperPath()
  if (script === undefined) throw new Error("The Linux Computer Use helper is not installed")
  const processHandle: ChildProcessWithoutNullStreams = spawn("python3", [script], {
    env: process.env as Record<string, string>,
    stdio: ["pipe", "pipe", "pipe"]
  })
  let stderr = ""
  processHandle.stderr.on("data", (chunk: Buffer) => {
    stderr = `${stderr}${chunk.toString("utf8")}`.slice(-8_000)
  })
  return jsonLineClient(
    (line) => processHandle.stdin.write(line),
    async () => {
      processHandle.stdin.end()
      processHandle.kill("SIGTERM")
    },
    (onData, onClose) => {
      processHandle.stdout.on("data", onData)
      processHandle.once("error", onClose)
      processHandle.once("exit", (code) =>
        onClose(new Error(stderr.trim() || `Linux Computer Use helper exited with ${code}`))
      )
    }
  )
}

/// The action verdict plus just enough context to notice that the app moved
/// underneath the caller (a new window, a dialog) without resending the whole
/// snapshot the next get_app_state will provide anyway.
const actionOutcome = (result: CallToolResult): CallToolResult => {
  const text = result.content?.find((entry) => entry.type === "text")?.text
  if (typeof text !== "string") return { content: [] }
  try {
    const state = JSON.parse(text) as Record<string, unknown>
    const outcome: Record<string, unknown> = { ...(state.action as object | undefined) }
    for (const key of ["windowId", "focusedWindowId", "modalSheetPresent", "next"] as const) {
      if (state[key] !== undefined) outcome[key] = state[key]
    }
    const windows = state.windows
    if (Array.isArray(windows) && windows.length > 1) outcome.windowCount = windows.length
    if (Object.keys(outcome).length === 0) return { content: [] }
    return { content: [{ type: "text", text: JSON.stringify(outcome) }] }
  } catch {
    return { content: [] }
  }
}

export const makeComputerUseProvider = (
  dataDir: string
): AutomationToolProvider & {
  readonly ensureSetup: () => Promise<void>
  readonly status: () => Readonly<Record<string, unknown>>
} => {
  // On macOS each session gets its own bridge connection: the bridge serves
  // every connection concurrently but strictly serializes requests within one,
  // so a shared socket would force simultaneous agents to take turns. The
  // Linux helper is a spawned subprocess, so it stays shared there.
  const perSessionConnections = process.platform === "darwin"
  const helpers = new Map<string, Promise<HelperClient>>()
  const helperKey = (sessionId: string): string => (perSessionConnections ? sessionId : "shared")
  const cachedLinuxStatus = process.platform === "linux" ? linuxHelperStatus() : undefined
  const platformStatus = (): { readonly available: boolean; readonly detail?: string } => {
    if (process.platform === "darwin") {
      return macBridgeConfiguration(dataDir) === undefined
        ? { available: false, detail: "Open the native Codevisor app to use Computer Use" }
        : { available: true }
    }
    if (cachedLinuxStatus !== undefined) return cachedLinuxStatus
    return { available: false, detail: `Computer Use is unavailable on ${process.platform}` }
  }
  const connect = async (sessionId: string): Promise<HelperClient> => {
    const key = helperKey(sessionId)
    const existing = helpers.get(key)
    if (existing !== undefined) {
      const client = await existing
      // A dead transport (native app restarted, helper exited) would
      // otherwise stay memoized and fail every future request.
      if (!client.isClosed()) return client
      if (helpers.get(key) === existing) helpers.delete(key)
      return connect(sessionId)
    }
    const created = (
      process.platform === "darwin"
        ? connectMacHelper(dataDir)
        : process.platform === "linux"
          ? connectLinuxHelper()
          : Promise.reject(new Error(`Computer Use is unavailable on ${process.platform}`))
    ).catch((cause: unknown) => {
      if (helpers.get(key) === created) helpers.delete(key)
      throw cause
    })
    helpers.set(key, created)
    return created
  }
  const release = async (sessionId: string): Promise<void> => {
    const key = helperKey(sessionId)
    const pending = helpers.get(key)
    if (pending === undefined) return
    helpers.delete(key)
    const active = await pending.catch(() => undefined)
    await active?.close().catch(() => undefined)
  }

  return {
    id: "computer",
    tools: computerUseTools,
    ensureSetup: async () => {
      const client = await connect("setup")
      try {
        await client.request({ type: "tool", sessionId: "setup", tool: "list_apps", arguments: {} })
      } finally {
        // The probe connection has no session behind it; keeping it open
        // would hold a bridge serving slot for nothing.
        if (perSessionConnections) await release("setup")
      }
    },
    status: () => ({ platform: process.platform, ...platformStatus() }),
    invoke: async (context, toolName, args) => {
      if (!computerUseTools.some((candidate) => candidate.name === toolName)) {
        return textToolResult(`Unknown Computer Use tool: ${toolName}`, true)
      }
      try {
        const result = await (
          await connect(context.sessionId)
        ).request({
          type: "tool",
          sessionId: context.sessionId,
          agentLabel: context.agentLabel,
          tool: toolName,
          arguments: args
        })
        // Native Computer Use action methods resolve void, and the full
        // post-action snapshot (tree + screenshot) is observed through
        // get_app_state. Returning nothing at all, though, hid whether the
        // event was delivered and whether the app changed — an ignored click
        // was indistinguishable from a real one. Keep the payload out, keep
        // the verdict in.
        if (toolName === "list_apps" || toolName === "get_app_state") return result
        return actionOutcome(result)
      } catch (cause) {
        return textToolResult(cause instanceof Error ? cause.message : String(cause), true)
      }
    },
    closeSession: async (sessionId) => {
      const active = await helpers.get(helperKey(sessionId))?.catch(() => undefined)
      await active?.request({ type: "closeSession", sessionId }).catch(() => undefined)
      if (perSessionConnections) await release(sessionId)
    },
    close: async () => {
      const pending = [...helpers.values()]
      helpers.clear()
      await Promise.all(
        pending.map(async (candidate) => {
          const active = await candidate.catch(() => undefined)
          await active?.close().catch(() => undefined)
        })
      )
    }
  }
}
