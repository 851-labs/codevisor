import { describe, expect, it } from "vitest"
import type { RuntimeEvent } from "@codevisor/agent-runtime"
import { run, setup } from "./test-support.js"

describe("CodexProvider", () => {
  it("plan mode sends the experimental collaboration mode on turn/start", async () => {
    const { client, created } = await setup()
    await run(created!.handle.setMode("plan"))
    const promptPromise = run(created!.handle.prompt("plan this"))
    await Promise.resolve()
    client.emit("turn/completed", {
      threadId: "thread-new",
      turn: { id: "t-plan", status: "completed" }
    })
    await promptPromise
    const turnStart = client.requests.find((request) => request.method === "turn/start")
    expect(turnStart?.params).toMatchObject({
      approvalPolicy: "never",
      collaborationMode: {
        mode: "plan",
        settings: {
          developer_instructions: null,
          model: "gpt-5.2-codex",
          reasoning_effort: "medium"
        }
      },
      sandboxPolicy: { type: "dangerFullAccess" }
    })
    // After leaving Plan mode, the reset collaboration mode ("default") rides
    // the next turn — codex's collaboration is sticky, so omitting it would
    // leave the model stuck in Plan mode.
    await run(created!.handle.setMode("agent"))
    const secondPrompt = run(created!.handle.prompt("implement"))
    await Promise.resolve()
    client.emit("turn/completed", {
      threadId: "thread-new",
      turn: { id: "t-agent", status: "completed" }
    })
    await secondPrompt
    const secondStart = client.requests.filter((request) => request.method === "turn/start").at(-1)
    expect(secondStart?.params).toMatchObject({
      collaborationMode: {
        mode: "default",
        settings: {
          developer_instructions: null,
          model: "gpt-5.2-codex",
          reasoning_effort: "medium"
        }
      }
    })
  })

  it("applies modes as approval/sandbox turn overrides and syncs effort to the model", async () => {
    const { client, created, events } = await setup()
    await run(created!.handle.setMode("agent-full-access"))
    expect(events.at(-1)?.payload).toMatchObject({ modeId: "agent-full-access" })
    await expect(run(created!.handle.setMode("nonsense"))).rejects.toThrow("Unknown Codex mode")

    // An effort the new model doesn't support clamps to that model's default;
    // xhigh is valid for gpt-5.2-codex but not gpt-5.5.
    await run(created!.handle.setConfigOption("effort", "xhigh"))
    await run(created!.handle.setConfigOption("model", "gpt-5.5"))
    const promptPromise = run(created!.handle.prompt("go"))
    await Promise.resolve()
    client.emit("turn/completed", {
      threadId: "thread-new",
      turn: { id: "t", status: "completed" }
    })
    await promptPromise
    const turnStart = client.requests.find((request) => request.method === "turn/start")
    expect(turnStart?.params).toMatchObject({
      approvalPolicy: "never",
      effort: "high",
      model: "gpt-5.5",
      sandboxPolicy: { type: "dangerFullAccess" }
    })
  })

  it("exposes speed for priority-tier models and applies it as a turn override", async () => {
    const { client, created, events } = await setup()
    const speedOption = created?.metadata.configOptions.find((option) => option.id === "speed")
    expect(speedOption).toMatchObject({
      category: "speed",
      currentValue: "standard",
      name: "Speed"
    })

    const runTurn = async (text: string, turnId: string): Promise<void> => {
      const promptPromise = run(created!.handle.prompt(text))
      await Promise.resolve()
      client.emit("turn/completed", {
        threadId: "thread-new",
        turn: { id: turnId, status: "completed" }
      })
      await promptPromise
    }
    const lastTurnStart = (): Record<string, unknown> =>
      client.requests.filter((request) => request.method === "turn/start").at(-1)?.params as Record<
        string,
        unknown
      >

    await run(created!.handle.setConfigOption("speed", "fast"))
    expect(events.at(-1)?.payload).toMatchObject({ configId: "speed", value: "fast" })
    await runTurn("go fast", "t1")
    expect(lastTurnStart()).toMatchObject({ serviceTier: "priority" })

    // Standard routes via the explicit "default" sentinel, not an omission.
    await run(created!.handle.setConfigOption("speed", "standard"))
    await runTurn("go normal", "t2")
    expect(lastTurnStart()).toMatchObject({ serviceTier: "default" })

    // A model without a fast tier drops the option and the tier override.
    await run(created!.handle.setConfigOption("model", "gpt-5.5"))
    const afterModel = events.at(-1)?.payload as { configOptions?: Array<{ id: string }> }
    expect(afterModel.configOptions).not.toContainEqual(expect.objectContaining({ id: "speed" }))
    await runTurn("go", "t3")
    expect("serviceTier" in lastTurnStart()).toBe(false)
  })

  it("interrupts: turn/interrupt is sent and the turn ends cancelled", async () => {
    const { client, created, events } = await setup()
    const promptPromise = run(created!.handle.prompt("long work"))
    await Promise.resolve()
    client.emit("turn/started", {
      threadId: "thread-new",
      turn: { id: "turn-9", status: "inProgress" }
    })
    await Promise.resolve()

    await run(created!.handle.cancel)
    expect(client.requests.at(-1)).toMatchObject({
      method: "turn/interrupt",
      params: { threadId: "thread-new", turnId: "turn-9" }
    })
    client.emit("turn/completed", {
      threadId: "thread-new",
      turn: { id: "turn-9", status: "interrupted" }
    })
    const result = await promptPromise
    expect(result.stopReason).toBe("cancelled")
    expect(events.every((event) => event.kind !== "session.error")).toBe(true)
  })

  it("applies model/effort overrides as sticky turn/start params", async () => {
    const { client, created } = await setup()
    const events: Array<RuntimeEvent> = []
    void events
    await run(created!.handle.setConfigOption("effort", "high"))
    const promptPromise = run(created!.handle.prompt("go"))
    await Promise.resolve()
    client.emit("turn/completed", {
      threadId: "thread-new",
      turn: { id: "t", status: "completed" }
    })
    await promptPromise
    const turnStart = client.requests.find((request) => request.method === "turn/start")
    expect(turnStart?.params).toMatchObject({ effort: "high", model: "gpt-5.2-codex" })
  })

  it("closing a session is silent: pending prompt cancels, no session.error", async () => {
    const { client, created, events } = await setup()
    const prompt = run(created!.handle.prompt("hello"))
    client.emit("turn/started", { threadId: "thread-new", turn: { id: "turn-close" } })
    // Deliberate teardown (agent replacement, session close) — must not
    // masquerade as a crash.
    await run(created!.handle.close)
    await expect(prompt).resolves.toMatchObject({ stopReason: "cancelled" })
    expect(client.closed).toBe(true)
    expect(events.every((event) => event.kind !== "session.error")).toBe(true)
  })
})
