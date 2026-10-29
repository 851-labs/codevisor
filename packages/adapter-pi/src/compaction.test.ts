import { describe, expect, it } from "vitest"

import { definition, payloads, run, setup } from "./test-support.js"

const turnEnds = (events: ReadonlyArray<{ payload: unknown }>) =>
  payloads(events).flatMap((payload) =>
    payload.turnState === "ended"
      ? [[payload.stopReason, ...(payload.stopDetail === undefined ? [] : [payload.stopDetail])]]
      : []
  )

describe("Pi compaction", () => {
  it("compacts with Pi's own command, passing any focus instructions", async () => {
    const { provider, client, events, emit } = setup()
    const { handle } = await run(provider.createSession(definition, "/p", emit))
    await expect(run(handle.prompt("/compact"))).resolves.toEqual({ stopReason: "end_turn" })
    await run(handle.prompt("/compact keep the API notes"))
    client.replies.compact = new Error("Nothing to compact")
    await run(handle.prompt("/compact"))

    expect(client.commands.map((command) => command.type)).not.toContain("prompt")
    expect(client.commands.filter((command) => command.type === "compact")).toEqual([
      { type: "compact", fields: {} },
      { type: "compact", fields: { customInstructions: "keep the API notes" } },
      { type: "compact", fields: {} }
    ])
    expect(turnEnds(events)).toEqual([
      ["end_turn"],
      ["end_turn"],
      ["end_turn", "Nothing to compact"]
    ])
  })

  it("ends a cancelled compaction as cancelled, without an error", async () => {
    const { provider, client, events, emit } = setup()
    const { handle } = await run(provider.createSession(definition, "/p", emit))
    const compaction = Promise.withResolvers<never>()
    client.replies.compact = compaction.promise
    const requested = client.nextCommand("compact")
    const compacting = run(handle.prompt("/compact"))
    await requested

    await run(handle.cancel)
    compaction.reject(new Error("Compaction cancelled"))

    await expect(compacting).resolves.toEqual({ stopReason: "cancelled" })
    expect(turnEnds(events)).toEqual([["cancelled"]])
  })
})
