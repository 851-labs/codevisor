import { describe, expect, it } from "vitest"
import { HubMetrics } from "../src/hub-metrics.js"

const capture = (): { lines: Record<string, unknown>[]; metrics: HubMetrics; tick: () => void } => {
  const lines: Record<string, unknown>[] = []
  let now = 1_000
  const metrics = new HubMetrics(
    (line) => lines.push(JSON.parse(line) as Record<string, unknown>),
    () => now
  )
  return { lines, metrics, tick: () => (now += 500) }
}

describe("hub metrics", () => {
  it("emits hello outcomes with resume attribution", () => {
    const { lines, metrics } = capture()
    metrics.hello("app", false, false)
    metrics.hello("machine", true, true)
    metrics.hello("app", false, true) // declined resume
    expect(lines).toEqual([
      { src: "hub", evt: "hello", kind: "app", resumed: false, presented: false },
      { src: "hub", evt: "hello", kind: "machine", resumed: true, presented: true },
      { src: "hub", evt: "hello", kind: "app", resumed: false, presented: true }
    ])
  })

  it("summarizes per-connection relay traffic at session end, then forgets it", () => {
    const { lines, metrics, tick } = capture()
    metrics.countRelay("c-1", 100)
    tick()
    metrics.countRelay("c-1", 50)
    metrics.sessionEnd({ kind: "app", connectionId: "c-1", helloDone: true, deviceId: "dev-1" })
    // A connection that never relayed still gets a summary (zeroes).
    metrics.sessionEnd({ kind: "machine", connectionId: "c-2", helloDone: true })
    expect(lines).toEqual([
      {
        src: "hub",
        evt: "session-end",
        kind: "app",
        deviceId: "dev-1",
        relayMessages: 2,
        relayBytes: 150,
        durationMs: 500
      },
      {
        src: "hub",
        evt: "session-end",
        kind: "machine",
        deviceId: null,
        relayMessages: 0,
        relayBytes: 0,
        durationMs: 0
      }
    ])
    // Totals were cleared with the summary.
    metrics.sessionEnd({ kind: "app", connectionId: "c-1", helloDone: true })
    expect(lines.at(-1)).toMatchObject({ relayMessages: 0, relayBytes: 0 })
  })

  it("reports expired grace windows and non-empty replays only", () => {
    const { lines, metrics } = capture()
    metrics.countRelay("c-3", 10)
    metrics.resumeExpired({
      connection_id: "c-3",
      kind: "machine",
      device_id: "dev-3",
      public_key: null,
      resume_token_hash: "",
      expires_at: null
    })
    metrics.replayed("c-4", 0)
    metrics.replayed("c-4", 7)
    expect(lines).toEqual([
      { src: "hub", evt: "resume-expired", kind: "machine", deviceId: "dev-3" },
      { src: "hub", evt: "resume-replay", connectionId: "c-4", messages: 7 }
    ])
  })
})
