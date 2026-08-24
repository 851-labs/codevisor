import { encodeRelayEnvelopes } from "@codevisor/api"

/// The machine-side relay connection's transport surface, reconnect policy,
/// and outgoing-envelope coalescing — split from machine-connection.ts so
/// each module stays within the size ratchet.

/// Minimal WebSocket surface both `ws` (Node/Bun) and the browser API can be
/// adapted to; injected so the connection logic is unit-testable. Text frames
/// carry JSON control messages; binary frames carry relay envelopes.
export interface CloudSocket {
  send(data: string | Uint8Array): void
  close(code?: number, reason?: string): void
  /// Immediately tears down the underlying transport. Node's `ws.terminate()`
  /// is essential for half-open TCP connections where a graceful close can
  /// wait forever; browser-style adapters may omit it and fall back to close.
  terminate?: () => void
  onopen: (() => void) | null
  onmessage: ((data: string | Uint8Array) => void) | null
  onclose: ((code: number) => void) | null
}

export type SocketFactory = (url: string, headers: Record<string, string>) => CloudSocket

export type MachineConnectionState =
  | "connecting"
  | "connected"
  | "reconnecting"
  | "stopped"
  /// Fatal states — the hub told us not to come back with these credentials.
  | "revoked"
  | "unsupported-protocol"

export type MachineDisconnectReason =
  | { kind: "socket-closed"; code: number }
  | { kind: "welcome-timeout" }
  | { kind: "heartbeat-timeout" }
  | { kind: "send-failed"; phase: "hello" | "heartbeat" }

export type CancelTimeout = () => void

/// Exponential backoff with full jitter; exported for tests and reuse.
export const reconnectDelayMs = (
  attempt: number,
  random: () => number,
  baseMs = 500,
  maxMs = 30_000
): number => Math.floor(random() * Math.min(maxMs, baseMs * 2 ** Math.min(attempt, 10)))

/// Estimated per-envelope framing overhead (header JSON + length prefixes)
/// used for the flush-early threshold.
const ENVELOPE_OVERHEAD_BYTES = 128

export interface RelayOutboxOptions {
  /// Delivers one encoded binary relay message (may contain many envelopes).
  send: (message: Uint8Array) => void
  scheduleTimeout: (callback: () => void, delayMs: number) => CancelTimeout
  /// 0 sends every envelope immediately as its own message. Positive values
  /// buffer envelopes for up to this long and flush them as one message — a
  /// Nagle for the relay. Chatty producers (a PTY writing per chunk) become a
  /// few messages instead of hundreds, which is what the hub bills and what
  /// wakes radios; the added latency is far below network RTT.
  coalesceMs: number
  /// Flush immediately once this much payload is buffered (default 256 KiB).
  maxBufferedBytes?: number
}

/// Order-preserving buffer of outgoing relay envelopes for one socket. All
/// relay sends go through here so coalescing can never reorder frames; the
/// owner clears it when its socket dies (channels die with the socket, so
/// buffered frames are moot).
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
    if (this.#pendingBytes >= (this.options.maxBufferedBytes ?? 256 * 1024)) {
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

  /// Drops buffered envelopes without sending (the socket is gone).
  clear(): void {
    this.#cancelFlush?.()
    this.#cancelFlush = undefined
    this.#pending = []
    this.#pendingBytes = 0
  }
}
