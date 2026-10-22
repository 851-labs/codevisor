import { spawn } from "node:child_process"

import { childStdioEndpoint, makeNdjsonTransport } from "@codevisor/agent-runtime"
import type { NdjsonTransport } from "@codevisor/agent-runtime"
import {
  processIdentity,
  stopProcessTree,
  stopTreeOnExit,
  trackProcessTree
} from "@codevisor/processes"

import {
  MINIMUM_MUSE_VERSION,
  record,
  TESTED_SCHEMA_FINGERPRINT,
  text,
  versionAtLeast
} from "./protocol.js"

export interface MuseClient {
  request: (method: string, params?: unknown) => Promise<unknown>
  notify: (method: string, params?: unknown) => void
  onNotification: (handler: (method: string, params: unknown) => void) => void
  onRequest: (handler: (method: string, params: unknown) => unknown) => void
  onClose: (handler: (error: Error) => void) => void
  close: () => void
}

export interface MuseSpawnRequest {
  readonly command: string
  readonly args: ReadonlyArray<string>
  readonly cwd: string
  readonly env: NodeJS.ProcessEnv
}

export type MuseConnector = (request: MuseSpawnRequest) => Promise<MuseClient>

export class MuseRequestError extends Error {
  constructor(
    message: string,
    readonly code: number | undefined,
    readonly kind: string | undefined
  ) {
    super(message)
  }
}

export class MuseExitedError extends Error {}

export const museExitMessage = (code: number | null, fallback: string): string => {
  switch (code) {
    case 3:
      return "Muse couldn't load its settings or sign-in. Sign in to Muse again."
    case 4:
      return "This Muse session is open in another Muse window. Close it there and try again."
    case 5:
      return "This Muse Code build doesn't include the session host Codevisor needs."
    default:
      return fallback
  }
}

/* v8 ignore start */
export const spawnMuseClient: MuseConnector = async (request) => {
  const child = spawn(request.command, ["serve", ...request.args], {
    cwd: request.cwd,
    env: request.env,
    detached: process.platform !== "win32",
    stdio: ["pipe", "pipe", "pipe"]
  })
  await new Promise<void>((resolve, reject) => {
    child.once("spawn", () => resolve())
    child.once("error", reject)
  })
  const endpoint = childStdioEndpoint(child)
  const transport = makeNdjsonTransport(
    {
      ...endpoint,
      onExit: (handler) =>
        endpoint.onExit((error) => {
          const explained = museExitMessage(child.exitCode, "")
          handler(error ?? (explained === "" ? undefined : new MuseExitedError(explained)))
        })
    },
    { exitMessage: "muse exited" }
  )
  const client = wireMuseClient(transport)
  const pid = child.pid!
  const identity = await processIdentity(pid)
  const tree = await trackProcessTree(pid)
  stopTreeOnExit(child, tree)
  return {
    ...client,
    close: () => {
      client.close()
      let stopping: Promise<void>
      if (identity === undefined) stopping = Promise.resolve()
      else stopping = stopProcessTree(pid, { identity })
      void stopping.catch(() => child.kill())
    }
  }
}
/* v8 ignore stop */

interface Pending {
  readonly resolve: (value: unknown) => void
  readonly reject: (error: Error) => void
}

export const wireMuseClient = (transport: NdjsonTransport): MuseClient => {
  let nextId = 1
  const pending = new Map<number, Pending>()
  let notificationHandler: ((method: string, params: unknown) => void) | undefined
  let requestHandler: ((method: string, params: unknown) => unknown) | undefined
  const closeHandlers: Array<(error: Error) => void> = []
  let closed = false

  const settle = (error: Error, notifyClose: boolean): void => {
    if (closed) return
    closed = true
    for (const entry of pending.values()) entry.reject(error)
    pending.clear()
    if (notifyClose) for (const handler of closeHandlers) handler(error)
  }

  transport.onFailure((error) =>
    settle(error instanceof MuseExitedError ? error : new MuseExitedError(error.message), true)
  )

  const reply = (id: unknown, result: unknown) =>
    transport.send({ jsonrpc: "2.0", id, result: record(result) })
  const fail = (id: unknown, code: number, message: string) =>
    transport.send({ jsonrpc: "2.0", id, error: { code, message, data: { kind: "internal" } } })

  const handleResponse = (id: unknown, message: Record<string, unknown>): void => {
    if (typeof id !== "number") return
    const entry = pending.get(id)
    if (entry === undefined) return
    pending.delete(id)
    if (message.error === undefined || message.error === null) {
      entry.resolve(message.result)
      return
    }
    const error = record(message.error)
    entry.reject(
      new MuseRequestError(
        text(error.message) ?? "Muse rejected the request",
        typeof error.code === "number" ? error.code : undefined,
        text(record(error.data).kind)
      )
    )
    return
  }

  const handle = (message: Record<string, unknown>): void => {
    const id = message.id
    const method = message.method
    if (typeof method !== "string") {
      handleResponse(id, message)
      return
    }
    try {
      if (id === undefined) notificationHandler?.(method, message.params)
      else if (requestHandler === undefined) fail(id, -32601, `No handler for ${method}`)
      else reply(id, requestHandler(method, message.params))
    } catch (error) {
      console.error(`Error handling muse ${method}`, error)
      if (id !== undefined) fail(id, -32603, `Codevisor couldn't handle ${method}`)
    }
  }

  transport.onLine((line) => {
    let message: unknown
    try {
      message = JSON.parse(line)
    } catch {
      return
    }
    handle(record(message))
  })

  return {
    request: (method, params) =>
      new Promise((resolve, reject) => {
        if (closed) {
          reject(new MuseExitedError("muse is no longer running"))
          return
        }
        const id = nextId
        nextId += 1
        pending.set(id, { resolve, reject })
        transport.send({ jsonrpc: "2.0", id, method, ...(params === undefined ? {} : { params }) })
      }),
    notify: (method, params) =>
      transport.send({ jsonrpc: "2.0", method, ...(params === undefined ? {} : { params }) }),
    onNotification: (handler) => {
      notificationHandler = handler
    },
    onRequest: (handler) => {
      requestHandler = handler
    },
    onClose: (handler) => {
      closeHandlers.push(handler)
    },
    close: () => {
      settle(new Error("muse client closed"), false)
      transport.close()
    }
  }
}

export interface MuseHost {
  readonly version: string
  readonly experimentalApi: boolean
  readonly capabilities: ReadonlyArray<string>
}

export const handshake = async (
  client: MuseClient,
  warn: (message: string) => void = console.warn
): Promise<MuseHost> => {
  const result = record(
    await client.request("initialize", {
      clientInfo: { name: "codevisor", title: "Codevisor", version: "1" },
      capabilities: { experimentalApi: true, requestedCapabilities: ["sessionMcp"] }
    })
  )
  client.notify("initialized")
  const version = text(record(result.serverInfo).version) ?? "0"
  if (!versionAtLeast(version, MINIMUM_MUSE_VERSION)) {
    client.close()
    throw new Error(
      `This version of Muse Code (${version}) is too old for Codevisor. Update Muse Code to ${MINIMUM_MUSE_VERSION} or newer.`
    )
  }
  const fingerprint = text(record(result.schema).fingerprint)
  if (fingerprint !== TESTED_SCHEMA_FINGERPRINT)
    warn(
      `Muse Code ${version} speaks MSP schema ${fingerprint ?? "unknown"}; Codevisor was tested against ${TESTED_SCHEMA_FINGERPRINT}.`
    )
  return {
    version,
    experimentalApi: result.experimentalApi === true,
    capabilities: Array.isArray(result.grantedCapabilities)
      ? result.grantedCapabilities.filter((entry): entry is string => typeof entry === "string")
      : []
  }
}
