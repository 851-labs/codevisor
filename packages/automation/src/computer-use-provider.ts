import { spawn, spawnSync, type ChildProcessWithoutNullStreams } from "node:child_process"
import { randomUUID } from "node:crypto"
import { existsSync, readFileSync } from "node:fs"
import { createConnection, type Socket } from "node:net"
import { join } from "node:path"

import { CallToolResultSchema, type CallToolResult } from "@modelcontextprotocol/sdk/types.js"

import type { AutomationToolProvider } from "./automation-provider.js"
import { computerResultApp, textToolResult } from "./automation-provider.js"
import { makeRecordingArtifacts } from "./computer-use-recording-artifacts.js"
import { makeComputerUseRepls } from "./computer-use-repl.js"
import { computerUseTools } from "./computer-use-tools.js"
import { waitForComputerState } from "./computer-use-wait.js"
import { findServerResource, type ServerResourceOptions } from "./server-resources.js"
import { recordOrEmpty } from "./unknown-values.js"

export { computerUseTools } from "./computer-use-tools.js"
interface PendingRequest {
  readonly resolve: (value: unknown) => void
  readonly reject: (cause: Error) => void
  readonly cleanup: () => void
}

const HOUSEKEEPING_TIMEOUT_MS = 30_000
const NATIVE_REPLY_MARGIN_MS = 1_000

const housekeepingSignal = (): AbortSignal => {
  const controller = new AbortController()
  const timer = setTimeout(
    () => controller.abort(new Error("Computer Use helper timed out")),
    HOUSEKEEPING_TIMEOUT_MS
  )
  timer.unref?.()
  return controller.signal
}

const abortError = (signal: AbortSignal): Error =>
  signal.reason instanceof Error ? signal.reason : new Error("Computer Use request was cancelled")

const toolResult = (value: unknown): CallToolResult => {
  const parsed = CallToolResultSchema.safeParse(value)
  if (!parsed.success) throw new Error("Computer Use helper returned an invalid tool result")
  return parsed.data
}

interface HelperClient {
  readonly request: (
    payload: Readonly<Record<string, unknown>>,
    signal: AbortSignal
  ) => Promise<unknown>
  readonly close: () => Promise<void>
  readonly isClosed: () => boolean
}

const jsonLineClient = (
  write: (line: string) => void,
  closeTransport: () => Promise<void>,
  subscribe: (onData: (data: Buffer) => void, onClose: (cause?: Error) => void) => void,
  dropConnectionOnCancel: boolean
): HelperClient => {
  const pending = new Map<string, PendingRequest>()
  let buffer = ""
  let closed: Error | undefined
  const failAll = (cause = new Error("Computer Use helper closed")) => {
    closed = cause
    for (const request of pending.values()) {
      request.cleanup()
      request.reject(cause)
    }
    pending.clear()
  }
  const close = async () => {
    failAll()
    await closeTransport()
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
        const message = recordOrEmpty(JSON.parse(line))
        if (typeof message.id !== "string") continue
        const request = pending.get(message.id)
        if (request === undefined) continue
        pending.delete(message.id)
        request.cleanup()
        if (typeof message.error === "string")
          request.reject(Object.assign(new Error(message.error), { code: message.code }))
        else request.resolve(message.result)
      } catch {}
    }
  }, failAll)
  return {
    request: (payload, signal) => {
      if (closed !== undefined) return Promise.reject(closed)
      if (signal.aborted) return Promise.reject(abortError(signal))
      const id = randomUUID()
      return new Promise<unknown>((resolve, reject) => {
        const onAbort = () => {
          pending.delete(id)
          reject(abortError(signal))
          if (dropConnectionOnCancel) void close()
        }
        signal.addEventListener("abort", onAbort, { once: true })
        pending.set(id, {
          resolve,
          reject,
          cleanup: () => signal.removeEventListener("abort", onAbort)
        })
        write(`${JSON.stringify({ id, ...payload })}\n`)
      })
    },
    close,
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

export const macNativeHostAvailable = (dataDir: string): boolean =>
  macBridgeConfiguration(dataDir) !== undefined

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
    },
    true
  )
  try {
    await client.request({ type: "authenticate", token }, housekeepingSignal())
    return client
  } catch (cause) {
    await client.close()
    throw cause
  }
}

export const requestMacScreenSharing = async (
  dataDir: string,
  request: Readonly<Record<string, unknown>>
): Promise<unknown> => {
  const client = await connectMacHelper(dataDir)
  try {
    return await client.request({ type: "screenSharing", request }, housekeepingSignal())
  } finally {
    await client.close()
  }
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
    env: process.env,
    stdio: ["pipe", "pipe", "pipe"]
  })
  let stderr = ""
  processHandle.stdin.on("error", () => undefined)
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
    },
    false
  )
}

const computerUseDeclinedMessage = "The user didn't allow Computer Use on this Mac."

const permissionRequired = (cause: unknown): boolean =>
  cause instanceof Error && "code" in cause && cause.code === "accessibilityRequired"

export const makeComputerUseProvider = (
  dataDir: string
): AutomationToolProvider & {
  readonly ensureSetup: () => Promise<void>
  readonly status: () => Readonly<Record<string, unknown>>
} => {
  const perSessionConnections = process.platform === "darwin"
  const helpers = new Map<string, Promise<HelperClient>>()
  const repls = makeComputerUseRepls()
  const recordingArtifacts = makeRecordingArtifacts()
  const helperKey = (sessionId: string): string => (perSessionConnections ? sessionId : "shared")
  let linuxStatus: { readonly available: boolean; readonly detail?: string } | undefined
  const platformStatus = (): { readonly available: boolean; readonly detail?: string } => {
    if (process.platform === "darwin") {
      return macBridgeConfiguration(dataDir) === undefined
        ? { available: false, detail: "Open the native Codevisor app to use Computer Use" }
        : { available: true }
    }
    if (process.platform === "linux") {
      if (linuxStatus?.available !== true) linuxStatus = linuxHelperStatus()
      return linuxStatus
    }
    return { available: false, detail: `Computer Use is unavailable on ${process.platform}` }
  }
  const connect = async (sessionId: string): Promise<HelperClient> => {
    const key = helperKey(sessionId)
    const existing = helpers.get(key)
    if (existing !== undefined) {
      const client = await existing
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

  const provider: ReturnType<typeof makeComputerUseProvider> = {
    id: "computer",
    tools: computerUseTools,
    ensureSetup: async () => {
      const client = await connect("setup")
      try {
        await client.request(
          { type: "tool", sessionId: "setup", tool: "list_apps", arguments: {} },
          housekeepingSignal()
        )
      } finally {
        if (perSessionConnections) await release("setup")
      }
    },
    status: () => ({ platform: process.platform, ...platformStatus() }),
    invoke: async (context, toolName, args) => {
      if (!computerUseTools.some((candidate) => candidate.name === toolName)) {
        return textToolResult(`Unknown Computer Use tool: ${toolName}`, true)
      }
      const signal = context.signal ?? new AbortController().signal
      try {
        if (toolName === "js") {
          if (typeof args.code !== "string") return textToolResult("code is required", true)
          return await repls.execute(context.sessionId, args.code, (name, input) =>
            provider.invoke(context, name, input)
          )
        }
        if (toolName === "reset") {
          await repls.reset(context.sessionId)
          return textToolResult(JSON.stringify({ reset: true }))
        }
        if (toolName === "wait_for") {
          return await waitForComputerState(
            args,
            (input) => provider.invoke(context, "get_app_state", input),
            undefined,
            process.platform === "darwin"
              ? async (ms) => {
                  await (
                    await connect(context.sessionId)
                  ).request(
                    {
                      type: "tool",
                      sessionId: context.sessionId,
                      agentLabel: context.agentLabel,
                      tool: "await_change",
                      arguments: { app: args.app, timeout_ms: ms }
                    },
                    signal
                  )
                }
              : undefined,
            context.deadline
          )
        }
        if (
          (args.delivery_mode ?? args.deliveryMode) === "foreground" &&
          (typeof args.foreground_reason !== "string" || !args.foreground_reason.trim())
        ) {
          return textToolResult(
            "Foreground delivery requires foreground_reason explaining why background cannot complete this action.",
            true
          )
        }
        if (
          process.platform !== "darwin" &&
          (toolName === "find" ||
            (toolName === "get_app_state" && args.element_index !== undefined))
        ) {
          return textToolResult(
            "find and element_index reads are currently available in the native macOS Codevisor app.",
            true
          )
        }
        if (
          process.platform !== "darwin" &&
          [
            "list_recording_targets",
            "start_recording",
            "stop_recording",
            "recording_status"
          ].includes(toolName)
        ) {
          return textToolResult(
            "Screen recording is currently available in the native macOS Codevisor app.",
            true
          )
        }
        const result = toolResult(
          await (
            await connect(context.sessionId)
          ).request(
            {
              type: "tool",
              sessionId: context.sessionId,
              agentLabel: context.agentLabel,
              tool: toolName,
              arguments: args,
              ...(context.deadline === undefined
                ? {}
                : {
                    budgetMs: Math.max(
                      0,
                      Math.floor(context.deadline - performance.now() - NATIVE_REPLY_MARGIN_MS)
                    )
                  })
            },
            signal
          )
        )
        const app = computerResultApp(result)
        if (app !== undefined) context.onApp?.(app)
        return toolName === "stop_recording" || toolName === "recording_status"
          ? await recordingArtifacts.enrich(result, context)
          : result
      } catch (cause) {
        const { requestPermissions, ...retryContext } = context
        if (requestPermissions !== undefined && permissionRequired(cause)) {
          const allowed = await requestPermissions()
          if (!allowed) return textToolResult(computerUseDeclinedMessage, true)

          return provider.invoke(retryContext, toolName, args)
        }
        return textToolResult(cause instanceof Error ? cause.message : String(cause), true)
      }
    },
    finishTurn: async (sessionId) => {
      if (!perSessionConnections) return
      void helpers
        .get(helperKey(sessionId))
        ?.then((active) => active.request({ type: "finishTurn", sessionId }, housekeepingSignal()))
        .catch(() => undefined)
    },
    closeSession: async (sessionId) => {
      await repls.reset(sessionId)
      const active = await helpers.get(helperKey(sessionId))?.catch(() => undefined)
      await active
        ?.request({ type: "closeSession", sessionId }, housekeepingSignal())
        .catch(() => undefined)
      if (perSessionConnections) await release(sessionId)
      recordingArtifacts.closeSession(sessionId)
    },
    close: async () => {
      await repls.close()
      recordingArtifacts.clear()
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
  return provider
}
