/// The machine-side relay connection's transport surface and reconnect
/// policy, split from machine-connection.ts so each module stays within the
/// size ratchet.

/// Minimal WebSocket surface both `ws` (Node/Bun) and the browser API can be
/// adapted to; injected so the connection logic is unit-testable.
export interface CloudSocket {
  send(data: string): void
  close(code?: number, reason?: string): void
  /// Immediately tears down the underlying transport. Node's `ws.terminate()`
  /// is essential for half-open TCP connections where a graceful close can
  /// wait forever; browser-style adapters may omit it and fall back to close.
  terminate?: () => void
  onopen: (() => void) | null
  onmessage: ((data: string) => void) | null
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
