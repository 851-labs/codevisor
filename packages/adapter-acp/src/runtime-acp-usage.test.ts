import { turnUsageOf, type RuntimeEvent } from "@codevisor/agent-runtime"
import { Effect } from "effect"
import { describe, expect, it } from "vitest"

import { turnTokensOf } from "./prompt-usage.js"
import { FakeConnection, makeAcpAgentRuntime, payloadString, run } from "./test-support.js"

class CountingConnection extends FakeConnection {
  override prompt() {
    return Effect.succeed({
      stopReason: "end_turn",
      tokens: { inputTokens: 1200, outputTokens: 80, totalTokens: 1280 }
    })
  }
}

describe("ACP turn usage", () => {
  it("reports a turn's token usage before the turn ends", async () => {
    const runtime = makeAcpAgentRuntime({
      connector: {
        connect: (request, emit) => Effect.succeed(new CountingConnection(request, emit))
      },
      env: { PATH: "/bin" },
      executableExists: (name) => name === "gemini",
      locateExecutable: (name) => `/bin/${name}`
    })
    const events: Array<RuntimeEvent> = []
    const sessionId = await run(
      runtime.createAgentSession("gemini", "/tmp/project", (event) => {
        events.push(event)
      })
    )

    await run(runtime.prompt(sessionId, "hello"))
    const usageIndex = events.findIndex((event) => turnUsageOf(event.payload) !== undefined)
    const endIndex = events.findIndex((event) => payloadString(event, "turnState") === "ended")
    expect(turnUsageOf(events[usageIndex]?.payload)).toEqual({
      inputTokens: 1200,
      outputTokens: 80,
      totalTokens: 1280
    })
    expect(usageIndex).toBeGreaterThan(-1)
    expect(usageIndex).toBeLessThan(endIndex)
  })

  it("maps ACP's prompt usage onto Codevisor's token fields", () => {
    expect(turnTokensOf(undefined)).toBeUndefined()
    expect(turnTokensOf(null)).toBeUndefined()
    expect(
      turnTokensOf({
        inputTokens: 900,
        outputTokens: 40,
        totalTokens: 1000,
        thoughtTokens: 20,
        cachedReadTokens: 300,
        cachedWriteTokens: null
      })
    ).toEqual({
      inputTokens: 900,
      outputTokens: 40,
      totalTokens: 1000,
      reasoningOutputTokens: 20,
      cachedInputTokens: 300
    })
  })
})
