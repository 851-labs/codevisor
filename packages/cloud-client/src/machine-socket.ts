import { decodeHubToMachine, encodeRelayEnvelopes, type HubToMachine } from "@codevisor/api"

export interface CloudSocket {
  send(data: string | Uint8Array): void
  close(code?: number, reason?: string): void
  terminate?: () => void
  onopen: (() => void) | null
  onmessage: ((data: string | Uint8Array) => void) | null
  onclose: ((code: number) => void) | null
  onrejected?: ((status: number) => void) | null
}

export type SocketFactory = (url: string, headers: Record<string, string>) => CloudSocket

export type MachineConnectionState =
  | "connecting"
  | "connected"
  | "reconnecting"
  | "stopped"
  | "revoked"
  | "unsupported-protocol"

export type MachineDisconnectReason =
  | { kind: "socket-closed"; code: number }
  | { kind: "upgrade-rejected"; status: number }
  | { kind: "welcome-timeout" }
  | { kind: "heartbeat-timeout" }
  | { kind: "send-failed"; phase: "hello" | "heartbeat" }

export type CancelTimeout = () => void

export const decodeHubFrame = (data: string): HubToMachine | undefined => {
  try {
    return decodeHubToMachine(data)
  } catch {
    return undefined
  }
}

export const isCredentialRejection = (status: number): boolean => status === 401 || status === 403

export const REVOKED_RECHECK_MS = 5 * 60 * 1000

export const reconnectDelayMs = (
  attempt: number,
  random: () => number,
  baseMs = 500,
  maxMs = 30_000
): number => Math.floor(random() * Math.min(maxMs, baseMs * 2 ** Math.min(attempt, 10)))

const ENVELOPE_OVERHEAD_BYTES = 128

const MAX_BUFFERED_BYTES = 256 * 1024

export interface RelayOutboxOptions {
  send: (message: Uint8Array) => void
  scheduleTimeout: (callback: () => void, delayMs: number) => CancelTimeout
  coalesceMs: number
}

export class RelayOutbox {
  #pending: { header: unknown; payload: Uint8Array }[] = []
  #pendingBytes = 0
  #cancelFlush: CancelTimeout | undefined

  constructor(private readonly options: RelayOutboxOptions) {}

  push(header: unknown, payload: Uint8Array): void {
    if (this.options.coalesceMs <= 0) {
      this.options.send(encodeRelayEnvelopes([{ header, payload }]))
      return
    }
    this.#pending.push({ header, payload })
    this.#pendingBytes += payload.byteLength + ENVELOPE_OVERHEAD_BYTES
    if (this.#pendingBytes >= MAX_BUFFERED_BYTES) {
      this.flush()
      return
    }
    this.#cancelFlush ??= this.options.scheduleTimeout(() => {
      this.#cancelFlush = undefined
      this.flush()
    }, this.options.coalesceMs)
  }

  flush(): void {
    this.#cancelFlush?.()
    this.#cancelFlush = undefined
    if (this.#pending.length === 0) return
    const pending = this.#pending
    this.#pending = []
    this.#pendingBytes = 0
    this.options.send(encodeRelayEnvelopes(pending))
  }

  clear(): void {
    this.drain()
  }

  drain(): { header: unknown; payload: Uint8Array }[] {
    this.#cancelFlush?.()
    this.#cancelFlush = undefined
    const pending = this.#pending
    this.#pending = []
    this.#pendingBytes = 0
    return pending
  }
}
