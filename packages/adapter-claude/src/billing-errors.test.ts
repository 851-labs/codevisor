import type { RuntimeEvent } from "@codevisor/agent-runtime"
import { describe, expect, it } from "vitest"

import {
  definition,
  FakeQuery,
  initMessage,
  makeProvider,
  payloadOf,
  resultWith,
  run,
  sdkMessage
} from "./test-support.js"

describe("Claude billing errors", () => {
  it("pauses an API-key account that runs out of credits instead of failing the turn", async () => {
    const creditsTooLow = "Credit balance is too low"
    for (const [content, stopDetail] of [
      [[{ text: creditsTooLow, type: "text" }], creditsTooLow],
      [[], "Claude usage credits are required to continue."]
    ] as const) {
      const fake = new FakeQuery()
      const provider = makeProvider(fake)
      const events: Array<RuntimeEvent> = []
      const createPromise = run(
        provider.createSession(definition, "/tmp", async (event) => {
          events.push(event)
        })
      )
      fake.push(initMessage())
      const created = await createPromise

      const promptPromise = run(created.handle.prompt("do work"))
      await fake.nextPrompt()
      fake.push(
        sdkMessage({
          error: "billing_error",
          message: { content, id: "msg-billing", role: "assistant" },
          parent_tool_use_id: null,
          session_id: "sdk-session-1",
          type: "assistant",
          uuid: "00000000-0000-0000-0000-000000000003"
        })
      )
      fake.push(resultWith({ is_error: true, result: creditsTooLow }))

      await promptPromise
      const endedPayload = events.map(payloadOf).find((payload) => payload.turnState === "ended")
      expect(endedPayload).toMatchObject({ stopDetail, stopKind: "usageLimit" })
      expect(endedPayload?.retryable).toBeUndefined()
    }
  })
})
