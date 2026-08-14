import WebSocket, { type RawData } from "ws"

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

export class CdpConnection {
  readonly #socket: WebSocket
  readonly #pending = new Map<number, PendingCommand>()
  readonly #handlers = new Map<string, Set<EventHandler>>()
  #nextId = 1
  #closed: Error | undefined

  private constructor(socket: WebSocket) {
    this.#socket = socket
    socket.on("message", (data) => this.#receive(data))
    socket.on("error", (cause) => this.#fail(cause))
    socket.on("close", () => this.#fail(new Error("Browser debugging connection closed")))
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

  static fromSocket(socket: WebSocket): CdpConnection {
    if (socket.readyState !== WebSocket.OPEN) {
      throw new Error("Browser relay socket is not open")
    }
    return new CdpConnection(socket)
  }

  send<T = Readonly<Record<string, unknown>>>(
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
        resolve: resolve as (value: unknown) => void,
        reject,
        timer
      })
      this.#socket.send(
        JSON.stringify({ id, method, params, ...(sessionId === undefined ? {} : { sessionId }) })
      )
    })
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

  #receive(data: RawData): void {
    let message: {
      id?: unknown
      result?: unknown
      error?: { message?: unknown; data?: unknown }
      method?: unknown
      params?: unknown
      sessionId?: unknown
    }
    try {
      message = JSON.parse(data.toString()) as typeof message
    } catch {
      return
    }
    if (typeof message.id === "number") {
      const pending = this.#pending.get(message.id)
      if (pending === undefined) return
      this.#pending.delete(message.id)
      clearTimeout(pending.timer)
      if (message.error !== undefined) {
        const detail = typeof message.error.data === "string" ? `: ${message.error.data}` : ""
        pending.reject(
          new Error(`${String(message.error.message ?? "Browser command failed")}${detail}`)
        )
      } else pending.resolve(message.result ?? {})
      return
    }
    if (typeof message.method !== "string") return
    const params =
      message.params !== null && typeof message.params === "object"
        ? (message.params as Readonly<Record<string, unknown>>)
        : {}
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

export const evaluatedValue = <T>(response: unknown): T => {
  const result = (response as { result?: { value?: unknown; description?: unknown } }).result
  if (result === undefined) throw new Error("Browser evaluation returned no result")
  if (!("value" in result)) {
    throw new Error(
      `Browser evaluation could not be serialized: ${String(result.description ?? "unknown")}`
    )
  }
  return result.value as T
}
