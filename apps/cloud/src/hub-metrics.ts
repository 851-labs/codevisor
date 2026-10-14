import type { SocketAttachment } from "./hub-schema.js"
import type { ResumeSessionRow } from "./resume-sessions.js"

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

  hello(kind: "app" | "machine", resumed: boolean, presentedResumeToken: boolean): void {
    this.#emit({ evt: "hello", kind, resumed, presented: presentedResumeToken })
  }

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

  resumeExpired(session: ResumeSessionRow): void {
    this.#traffic.delete(session.connection_id)
    this.#emit({ evt: "resume-expired", kind: session.kind, deviceId: session.device_id })
  }

  replayed(connectionId: string, messages: number): void {
    if (messages === 0) return
    this.#emit({ evt: "resume-replay", connectionId, messages })
  }
}
