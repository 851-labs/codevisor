import type { SocketAttachment } from "./hub-schema.js"
import type { ResumeSessionRow } from "./resume-sessions.js"

/// Structured observability for the relay hub: one JSON line per meaningful
/// event, written to console so Workers Logs ingests it — queryable by field
/// in the dashboard with zero extra infrastructure (own the stack; the
/// observability toggle is already on).
///
/// Events (all carry `src: "hub"` and `evt`):
/// - `hello`          kind, resumed, presented   — every completed hello;
///                    `presented` = a resume token was offered. resumed=false
///                    with presented=true is a declined resume (expired,
///                    rotated, or hub redeployed) — the resume success rate
///                    is count(resumed) / count(presented).
/// - `session-end`    kind, deviceId, relayMessages, relayBytes, durationMs —
///                    per-connection relay totals. Counters live in memory,
///                    so a hibernation resets them: totals are "since the DO
///                    last woke", which is exactly the traffic that cost
///                    anything.
/// - `resume-expired` kind, deviceId — a grace window lapsed unresumed and
///                    the deferred death notices fired.
/// - `resume-replay`  kind-agnostic: messages handed to a resumed socket.
///
/// The hub never logs payload content — everything relayed is sealed, and
/// these events carry only sizes, kinds, and device ids.
export class HubMetrics {
  readonly #sink: (line: string) => void
  readonly #now: () => number
  readonly #traffic = new Map<
    string,
    { relayMessages: number; relayBytes: number; since: number }
  >()

  constructor(sink: (line: string) => void = console.log, now: () => number = Date.now) {
    this.#sink = sink
    this.#now = now
  }

  #emit(event: Record<string, unknown>): void {
    this.#sink(JSON.stringify({ src: "hub", ...event }))
  }

  /// Counts one inbound relay message from a connection.
  countRelay(connectionId: string, bytes: number): void {
    const entry = this.#traffic.get(connectionId) ?? {
      relayMessages: 0,
      relayBytes: 0,
      since: this.#now()
    }
    entry.relayMessages += 1
    entry.relayBytes += bytes
    this.#traffic.set(connectionId, entry)
  }

  /// A completed hello — fresh or resumed.
  hello(kind: "app" | "machine", resumed: boolean, presentedResumeToken: boolean): void {
    this.#emit({ evt: "hello", kind, resumed, presented: presentedResumeToken })
  }

  /// A socket departed for good: emit and clear its traffic totals.
  sessionEnd(attachment: SocketAttachment): void {
    const traffic = this.#traffic.get(attachment.connectionId)
    this.#traffic.delete(attachment.connectionId)
    this.#emit({
      evt: "session-end",
      kind: attachment.kind,
      deviceId: attachment.deviceId ?? null,
      relayMessages: traffic?.relayMessages ?? 0,
      relayBytes: traffic?.relayBytes ?? 0,
      durationMs: traffic === undefined ? 0 : this.#now() - traffic.since
    })
  }

  /// A resume grace window lapsed and the deferred death notices fired.
  resumeExpired(session: ResumeSessionRow): void {
    this.#traffic.delete(session.connection_id)
    this.#emit({ evt: "resume-expired", kind: session.kind, deviceId: session.device_id })
  }

  /// Buffered messages replayed onto a resumed socket.
  replayed(connectionId: string, messages: number): void {
    if (messages === 0) return
    this.#emit({ evt: "resume-replay", connectionId, messages })
  }
}
