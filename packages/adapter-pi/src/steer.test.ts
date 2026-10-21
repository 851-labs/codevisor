import { describe, expect, it } from "vitest"

import { definition, payloads, run, setup } from "./test-support.js"

const turnStates = (events: ReadonlyArray<{ payload: unknown }>) =>
  payloads(events).flatMap((payload) =>
    payload.turnState === undefined ? [] : [[payload.turnState, payload.initiatedBy]]
  )

const startedTurn = async () => {
  const { provider, client, events, emit } = setup()
  const { handle } = await run(provider.createSession(definition, "/p", emit))
  const steer = handle.steer
  if (steer === undefined) throw new Error("Pi sessions steer")
  const requested = client.nextCommand("prompt")
  const prompt = run(handle.prompt("do work"))
  await requested
  return { client, events, handle, prompt, steer: (text: string) => run(steer(text)) }
}

describe("Pi steering", () => {
  it("steers the running turn and declines once it is cancelled or settled", async () => {
    const { provider, client, emit } = setup()
    const { handle } = await run(provider.createSession(definition, "/p", emit))
    await expect(run(handle.steer!("too early"))).resolves.toBe(false)
    expect(client.commands.filter((command) => command.type === "prompt")).toEqual([])

    const running = await startedTurn()
    running.client.replies.prompt = { disposition: "queued" }
    await expect(running.steer("also check the tests")).resolves.toBe(true)
    expect(running.client.commands.at(-1)).toEqual({
      type: "prompt",
      fields: { message: "also check the tests", streamingBehavior: "steer" }
    })
    await run(running.handle.cancel)
    await expect(running.steer("after cancel")).resolves.toBe(false)
    running.client.emit({ type: "agent_settled" })
    await expect(running.prompt).resolves.toEqual({ stopReason: "cancelled" })
    await expect(running.steer("after")).resolves.toBe(false)
    expect(running.client.commands.filter((command) => command.type === "prompt")).toHaveLength(2)
  })

  it.each([
    { name: "a rejection", reply: new Error("Cannot submit a prompt while compaction is running") },
    { name: "no disposition", reply: "unexpected" }
  ])("declines a steer Pi answers with $name", async ({ reply }) => {
    const running = await startedTurn()
    running.client.replies.prompt = reply
    await expect(running.steer("also this")).resolves.toBe(false)
  })

  it("credits the user with a run Pi starts for a steer that arrived as it settled", async () => {
    const running = await startedTurn()
    const held = Promise.withResolvers<unknown>()
    running.client.replies.prompt = held.promise
    const requested = running.client.nextCommand("prompt")
    const steered = running.steer("one more thing")
    await requested
    running.client.emit({ type: "agent_settled" }, { type: "agent_start" })
    held.resolve({ disposition: "started" })
    await expect(steered).resolves.toBe(true)
    running.client.emit({ type: "agent_settled" }, { type: "agent_start" })
    expect(turnStates(running.events)).toEqual([
      ["started", "user"],
      ["ended", "user"],
      ["started", "user"],
      ["ended", "user"],
      ["started", "agent"]
    ])
  })
})
