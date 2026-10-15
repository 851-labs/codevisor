import { WebSocket } from "ws"

import { isRecord, recordOrEmpty, recordOrUndefined } from "./unknown-values.js"

interface PendingCommand {
  readonly resolve: (value: unknown) => void
  readonly reject: (cause: Error) => void
  readonly timer: ReturnType<typeof setTimeout>
}

export interface CdpEvent {
  readonly method: string
  readonly params: Readonly<Record<string, unknown>>
  readonly sessionId?: string
}

type EventHandler = (params: Readonly<Record<string, unknown>>, event: CdpEvent) => void

interface FailedSessionCommand {
  readonly cause: Error
  readonly method: string
  readonly params: Readonly<Record<string, unknown>>
  readonly sessionId: string
  readonly timeoutMs: number
}

type SessionRecoveryHandler = (command: FailedSessionCommand) => Promise<string | undefined>

interface CdpSocket {
  readonly readyState: number
  on(event: "message", listener: (data: Buffer) => void): unknown
  on(event: "error", listener: (error: Error) => void): unknown
  on(event: "close", listener: () => void): unknown
  once(event: "close", listener: () => void): unknown
  send(message: string): void
  close(): void
  terminate(): void
}
export class CdpConnection {
  readonly #socket: CdpSocket
  readonly #pending = new Map<number, PendingCommand>()
  readonly #handlers = new Map<string, Set<EventHandler>>()
  #nextId = 1
  #closed: Error | undefined
  #sessionRecoveryHandler: SessionRecoveryHandler | undefined

  private constructor(socket: CdpSocket) {
    this.#socket = socket
    socket.on("message", (data) => this.#receive(data))
    socket.on("error", (cause) => this.#fail(cause))
    socket.on("close", () => this.#fail(new Error("Browser debugging connection closed")))
  }

  get closed(): boolean {
    return this.#closed !== undefined
  }

  static connect(endpoint: string): Promise<CdpConnection> {
    return new Promise((resolve, reject) => {
      const socket = new WebSocket(endpoint, { maxPayload: 64 * 1024 * 1024 })
      const onError = (cause: Error) => reject(cause)
      socket.once("error", onError)
      socket.once("open", () => {
        socket.off("error", onError)
        resolve(new CdpConnection(socket))
      })
    })
  }

  static fromSocket(socket: CdpSocket): CdpConnection {
    if (socket.readyState !== WebSocket.OPEN) {
      throw new Error("Browser relay socket is not open")
    }
    return new CdpConnection(socket)
  }

  async send<T = Readonly<Record<string, unknown>>>(
    method: string,
    params: Readonly<Record<string, unknown>> = {},
    sessionId?: string,
    timeoutMs = 30_000
  ): Promise<T> {
    try {
      return await this.sendOnce<T>(method, params, sessionId, timeoutMs)
    } catch (cause) {
      const error = cause instanceof Error ? cause : new Error(String(cause))
      if (sessionId === undefined || this.#sessionRecoveryHandler === undefined) throw error
      const replacementSessionId = await this.#sessionRecoveryHandler({
        cause: error,
        method,
        params,
        sessionId,
        timeoutMs
      })
      if (replacementSessionId === undefined) throw error
      return await this.sendOnce<T>(method, params, replacementSessionId, timeoutMs)
    }
  }

  sendOnce<T = Readonly<Record<string, unknown>>>(
    method: string,
    params: Readonly<Record<string, unknown>> = {},
    sessionId?: string,
    timeoutMs = 30_000
  ): Promise<T> {
    if (this.#closed !== undefined) return Promise.reject(this.#closed)
    const id = this.#nextId++
    return new Promise<T>((resolve, reject) => {
      const timer = setTimeout(
        () => {
          this.#pending.delete(id)
          reject(new Error(`Browser command timed out: ${method}`))
        },
        Math.max(0, timeoutMs)
      )
      timer.unref?.()
      this.#pending.set(id, {
        // oxlint-disable-next-line typescript/no-unsafe-type-assertion
        resolve: resolve as (value: unknown) => void,
        reject,
        timer
      })
      this.#socket.send(
        JSON.stringify({ id, method, params, ...(sessionId === undefined ? {} : { sessionId }) })
      )
    })
  }

  setSessionRecoveryHandler(handler: SessionRecoveryHandler): () => void {
    this.#sessionRecoveryHandler = handler
    return () => {
      if (this.#sessionRecoveryHandler === handler) this.#sessionRecoveryHandler = undefined
    }
  }

  on(method: string, handler: EventHandler, sessionId?: string): () => void {
    const key = this.#eventKey(method, sessionId)
    const handlers = this.#handlers.get(key) ?? new Set<EventHandler>()
    handlers.add(handler)
    this.#handlers.set(key, handlers)
    return () => {
      handlers.delete(handler)
      if (handlers.size === 0) this.#handlers.delete(key)
    }
  }

  async close(): Promise<void> {
    if (this.#closed !== undefined) return
    this.#fail(new Error("Browser debugging connection closed"))
    await new Promise<void>((resolve) => {
      if (this.#socket.readyState === WebSocket.CLOSED) return resolve()
      this.#socket.once("close", () => resolve())
      this.#socket.close()
      const timer = setTimeout(() => {
        this.#socket.terminate()
        resolve()
      }, 1_000)
      timer.unref?.()
    })
  }

  #receive(data: Buffer): void {
    let parsed: unknown
    try {
      parsed = JSON.parse(data.toString())
    } catch {
      return
    }
    const message = recordOrEmpty(parsed)
    if (this.#settleResponse(message)) return
    this.#dispatchEvent(message)
  }

  #settleResponse(message: Record<string, unknown>): boolean {
    if (typeof message.id !== "number") return false
    const pending = this.#pending.get(message.id)
    if (pending === undefined) return true
    this.#pending.delete(message.id)
    clearTimeout(pending.timer)
    if (message.error !== undefined) {
      const error = recordOrEmpty(message.error)
      const summary = typeof error.message === "string" ? error.message : "Browser command failed"
      const detail = typeof error.data === "string" ? `: ${error.data}` : ""
      pending.reject(new Error(`${summary}${detail}`))
    } else pending.resolve(message.result ?? {})
    return true
  }

  #dispatchEvent(message: Record<string, unknown>): void {
    if (typeof message.method !== "string") return
    const params = recordOrEmpty(message.params)
    const sessionId = typeof message.sessionId === "string" ? message.sessionId : undefined
    const eventKeys = new Set([
      this.#eventKey(message.method, sessionId),
      this.#eventKey(message.method),
      this.#eventKey("*", sessionId),
      this.#eventKey("*")
    ])
    const event = {
      method: message.method,
      params,
      ...(sessionId === undefined ? {} : { sessionId })
    }
    for (const key of eventKeys) {
      for (const handler of this.#handlers.get(key) ?? []) handler(params, event)
    }
  }

  #eventKey(method: string, sessionId?: string): string {
    return `${sessionId ?? "*"}:${method}`
  }

  #fail(cause: Error): void {
    if (this.#closed !== undefined) return
    this.#closed = cause
    for (const pending of this.#pending.values()) {
      clearTimeout(pending.timer)
      pending.reject(cause)
    }
    this.#pending.clear()
  }
}

export const delay = (milliseconds: number): Promise<void> =>
  new Promise((resolve) => setTimeout(resolve, milliseconds))

export const evaluatedValue = (response: unknown): unknown => {
  const result = isRecord(response) ? recordOrUndefined(response.result) : undefined
  if (result === undefined) throw new Error("Browser evaluation returned no result")
  if (!("value" in result)) {
    throw new Error(
      `Browser evaluation could not be serialized: ${typeof result.description === "string" ? result.description : "unknown"}`
    )
  }
  return result.value
}
