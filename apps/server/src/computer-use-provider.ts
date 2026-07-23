import type { CallToolResult, Tool } from "@modelcontextprotocol/sdk/types.js"
import { randomUUID } from "node:crypto"
import { existsSync, readFileSync } from "node:fs"
import { createConnection, type Socket } from "node:net"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { spawn, spawnSync, type ChildProcessWithoutNullStreams } from "node:child_process"
import type { AutomationToolProvider } from "./automation-provider.js"
import { textToolResult } from "./automation-provider.js"
import { findServerResource, type ServerResourceOptions } from "./server-resources.js"

const objectSchema = (
  properties: Readonly<Record<string, unknown>> = {},
  required: ReadonlyArray<string> = []
) => ({
  type: "object",
  properties,
  ...(required.length === 0 ? {} : { required }),
  additionalProperties: false
})

const tool = (
  name: string,
  description: string,
  inputSchema: Readonly<Record<string, unknown>> = objectSchema()
): Tool => ({
  name,
  description,
  inputSchema: inputSchema as Tool["inputSchema"]
})

const appProperty = { type: "string", description: "App name, path, or bundle identifier" }
const nativeElementProperty = {
  type: "number",
  description: "Element index from the latest get_app_state result"
}

export const computerUseTools: ReadonlyArray<Tool> = [
  tool(
    "list_apps",
    "List installed desktop applications that Computer Use can inspect and control, including whether each app is running."
  ),
  tool(
    "get_app_state",
    "Launch the app if needed, then return its current accessibility text and screenshot. Re-snapshot before each action; element indices are snapshot-scoped.",
    objectSchema(
      {
        app: appProperty,
        disableDiff: {
          type: "boolean",
          description: "Native Computer Use option. true always returns the complete state."
        }
      },
      ["app"]
    )
  ),
  tool(
    "click",
    "Click an accessibility element or screenshot coordinate. Element clicks use an accessibility action when available and otherwise click the element's onscreen frame.",
    {
      type: "object",
      properties: {
        app: appProperty,
        element_index: nativeElementProperty,
        x: { type: "number" },
        y: { type: "number" },
        mouse_button: { type: "string", enum: ["left", "right", "middle", "l", "r", "m"] },
        click_count: { type: "number", minimum: 1, maximum: 2 }
      },
      required: ["app"],
      additionalProperties: false
    }
  ),
  tool(
    "drag",
    "Drag between two screenshot pixel coordinates.",
    objectSchema(
      {
        app: appProperty,
        from_x: { type: "number" },
        from_y: { type: "number" },
        to_x: { type: "number" },
        to_y: { type: "number" }
      },
      ["app", "from_x", "from_y", "to_x", "to_y"]
    )
  ),
  tool(
    "perform_secondary_action",
    "Perform an element's named accessibility action.",
    objectSchema(
      {
        app: appProperty,
        element_index: nativeElementProperty,
        action: { type: "string" }
      },
      ["app", "element_index", "action"]
    )
  ),
  tool(
    "press_key",
    "Press a real key or key chord in an app. Return, Tab, Delete, arrows, and modifiers are delivered as native key events.",
    objectSchema(
      {
        app: appProperty,
        key: { type: "string" }
      },
      ["app", "key"]
    )
  ),
  tool(
    "scroll",
    "Scroll an element or window by pages.",
    objectSchema(
      {
        app: appProperty,
        element_index: nativeElementProperty,
        direction: { type: "string", enum: ["up", "down", "left", "right", "u", "d", "l", "r"] },
        pages: { type: "number" }
      },
      ["app", "element_index", "direction"]
    )
  ),
  tool(
    "select_text",
    "Select an exact text match in an editable accessibility element, matching native Computer Use. Use prefix or suffix only to disambiguate repeated text. The selected range is preserved for the next formatting or keyboard action.",
    {
      type: "object",
      properties: {
        app: appProperty,
        element_index: nativeElementProperty,
        text: { type: "string", description: "Exact text to select in the editable value" },
        prefix: { type: "string", description: "Require this text immediately before text" },
        suffix: { type: "string", description: "Require this text immediately after text" },
        selection_type: {
          type: "string",
          enum: ["text", "cursor_before", "cursor_after"]
        }
      },
      required: ["app", "element_index", "text"],
      additionalProperties: false
    }
  ),
  tool(
    "set_value",
    "Set an accessibility element's value.",
    objectSchema(
      {
        app: appProperty,
        element_index: nativeElementProperty,
        value: { type: "string" }
      },
      ["app", "element_index", "value"]
    )
  ),
  tool(
    "type_text",
    "Type text into an editable element or the focused control.",
    objectSchema(
      {
        app: appProperty,
        text: { type: "string" }
      },
      ["app", "text"]
    )
  )
]

interface PendingRequest {
  readonly resolve: (value: CallToolResult) => void
  readonly reject: (cause: Error) => void
  readonly timer: ReturnType<typeof setTimeout>
}

interface HelperClient {
  readonly request: (payload: Readonly<Record<string, unknown>>) => Promise<CallToolResult>
  readonly close: () => Promise<void>
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
    }
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

const macBridgeConfiguration = (
  dataDir: string
): { readonly socketPath: string; readonly token: string } | undefined => {
  const envSocketPath = process.env.CODEVISOR_COMPUTER_USE_SOCKET
  const envToken = process.env.CODEVISOR_COMPUTER_USE_TOKEN
  if (envSocketPath !== undefined && envToken !== undefined) {
    return { socketPath: envSocketPath, token: envToken }
  }
  const socketPath = join(
    tmpdir(),
    `codevisor-cu-${process.getuid?.() ?? 0}-${stablePathHash(dataDir)}.sock`
  )
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

export const makeComputerUseProvider = (
  dataDir: string
): AutomationToolProvider & {
  readonly ensureSetup: () => Promise<void>
  readonly status: () => Readonly<Record<string, unknown>>
} => {
  let helper: Promise<HelperClient> | undefined
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
  const connect = (): Promise<HelperClient> => {
    if (helper !== undefined) return helper
    const created = (
      process.platform === "darwin"
        ? connectMacHelper(dataDir)
        : process.platform === "linux"
          ? connectLinuxHelper()
          : Promise.reject(new Error(`Computer Use is unavailable on ${process.platform}`))
    ).catch((cause) => {
      helper = undefined
      throw cause
    })
    helper = created
    return created
  }

  return {
    id: "computer",
    tools: computerUseTools,
    ensureSetup: async () => {
      await (
        await connect()
      ).request({ type: "tool", sessionId: "setup", tool: "list_apps", arguments: {} })
    },
    status: () => ({ platform: process.platform, ...platformStatus() }),
    invoke: async (context, toolName, args) => {
      if (!computerUseTools.some((candidate) => candidate.name === toolName)) {
        return textToolResult(`Unknown Computer Use tool: ${toolName}`, true)
      }
      try {
        const result = await (
          await connect()
        ).request({
          type: "tool",
          sessionId: context.sessionId,
          agentLabel: context.agentLabel,
          tool: toolName,
          arguments: args
        })
        // Native Computer Use action methods resolve void. The bridge still
        // snapshots after each action for presentation and fresh index state,
        // but callers observe that state through get_app_state just like sky.
        return toolName === "list_apps" || toolName === "get_app_state" ? result : { content: [] }
      } catch (cause) {
        return textToolResult(cause instanceof Error ? cause.message : String(cause), true)
      }
    },
    closeSession: async (sessionId) => {
      const active = await helper?.catch(() => undefined)
      await active?.request({ type: "closeSession", sessionId }).catch(() => undefined)
    },
    close: async () => {
      const active = await helper?.catch(() => undefined)
      helper = undefined
      await active?.close().catch(() => undefined)
    }
  }
}
