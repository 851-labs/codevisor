import { afterEach, describe, expect, it, vi } from "vitest"

import { piStop } from "./stops.js"
import { definition, payloads, run, setup } from "./test-support.js"

const chatGptLimit = "You have hit your ChatGPT usage limit (plus plan). Try again in ~142 min."

afterEach(() => {
  vi.useRealTimers()
})

describe("Pi usage-limit stops", () => {
  it("ends a turn stopped by the account's usage limit, with when it resets", async () => {
    vi.useFakeTimers({ toFake: ["Date"] })
    vi.setSystemTime(new Date("2026-10-20T12:00:00.000Z"))
    const { provider, client, events, emit } = setup()
    const { handle } = await run(provider.createSession(definition, "/p", emit))
    const requested = client.nextCommand("prompt")
    const prompted = run(handle.prompt("one"))
    await requested
    client.emit(
      { type: "message_start", message: { role: "assistant" } },
      {
        type: "message_end",
        message: { role: "assistant", stopReason: "error", errorMessage: chatGptLimit }
      },
      { type: "agent_settled" }
    )
    await prompted
    expect(payloads(events).filter((payload) => payload.turnState === "ended")).toEqual([
      {
        initiatedBy: "user",
        stopReason: "end_turn",
        stopDetail: chatGptLimit,
        stopKind: "usageLimit",
        resetsAt: "2026-10-20T14:22:00.000Z",
        turnId: expect.any(String),
        turnState: "ended"
      }
    ])
  })

  it("recognizes each provider's usage-limit error", () => {
    for (const stopDetail of [
      "You have hit your ChatGPT usage limit.",
      "Codex error: You've hit your usage limit for this period",
      "GoUsageLimitError: Monthly usage limit reached",
      "FreeUsageLimitError"
    ])
      expect(piStop(stopDetail)).toEqual({ stopDetail, stopKind: "usageLimit" })
  })

  it("leaves rate limits and other errors as a plain reason", () => {
    for (const stopDetail of [
      "429 rate limited",
      '429 {"type":"error","error":{"type":"rate_limit_error","message":"Rate limited"}}'
    ])
      expect(piStop(stopDetail)).toEqual({ stopDetail })
  })
})
