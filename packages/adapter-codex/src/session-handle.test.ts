import { describe, expect, it } from "vitest"

import { payloadField, payloadOf, recordOf, run, setup } from "./test-support.js"

describe("CodexProvider", () => {
  it("asks for reasoning summaries, so reasoning is reported as it starts, until the account refuses them", async () => {
    const { client, created } = await setup()
    const turn = async (id: string, turnState: Record<string, unknown>) => {
      const requested = client.nextRequest("turn/start")
      const prompt = run(created!.handle.prompt("go"))
      await requested
      client.emit("turn/completed", { threadId: "thread-new", turn: { id, ...turnState } })
      await prompt
      return client.requests.findLast((request) => request.method === "turn/start")?.params
    }
    expect(await turn("t1", { status: "completed" })).toMatchObject({ summary: "auto" })
    await turn("t2", { status: "failed", error: { message: "Rate limit reached" } })
    expect(await turn("t3", { status: "completed" })).toMatchObject({ summary: "auto" })
    await turn("t4", {
      status: "failed",
      error: { message: "Your organization must be verified to generate reasoning summaries." }
    })
    expect(await turn("t5", { status: "completed" })).not.toHaveProperty("summary")
  })

  it("forks the source thread into the new session", async () => {
    const { client, created } = await setup({ forkFrom: "thread-source" })

    expect(created?.metadata.sessionId).toBe("thread-fork")
    expect(
      client.requests.find((request) => request.method === "thread/fork")?.params
    ).toMatchObject({
      cwd: "/tmp/project",
      threadId: "thread-source",
      excludeTurns: true,
      deferGoalContinuation: true
    })
    expect(client.requests.map((request) => request.method)).not.toContain("thread/start")
  })

  it("compacts the thread natively when the prompt is /compact", async () => {
    const { client, created, events } = await setup()
    const compactRequested = client.nextRequest("thread/compact/start")
    const prompt = run(created!.handle.prompt("/compact"))
    await compactRequested
    client.emit("turn/started", { threadId: "thread-new", turn: { id: "t-compact" } })
    client.emit("turn/completed", {
      threadId: "thread-new",
      turn: { id: "t-compact", status: "completed" }
    })

    expect(await prompt).toEqual({ stopReason: "end_turn" })
    expect(client.requests.map((request) => request.method)).not.toContain("turn/start")
    expect(events.map(payloadOf)).toContainEqual(
      expect.objectContaining({ initiatedBy: "user", turnId: "t-compact", turnState: "started" })
    )
  })

  it("forgets a compaction Codex refuses, so the next turn isn't taken for it", async () => {
    const { client, created, events } = await setup()
    client.failCompaction = true

    await expect(run(created!.handle.prompt("/compact"))).rejects.toThrow("nothing to compact")
    client.emit("turn/started", { threadId: "thread-new", turn: { id: "t-agent" } })

    expect(events.map(payloadOf)).toContainEqual(
      expect.objectContaining({ initiatedBy: "agent", turnId: "t-agent", turnState: "started" })
    )
  })

  it("plan mode sends the experimental collaboration mode on turn/start", async () => {
    const { client, created } = await setup()
    await run(created!.handle.setMode("plan"))
    const turnRequested = client.nextRequest("turn/start")
    const promptPromise = run(created!.handle.prompt("plan this"))
    await turnRequested
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
    await run(created!.handle.setMode("agent"))
    const secondTurnRequested = client.nextRequest("turn/start")
    const secondPrompt = run(created!.handle.prompt("implement"))
    await secondTurnRequested
    client.emit("turn/completed", {
      threadId: "thread-new",
      turn: { id: "t-agent", status: "completed" }
    })
    await secondPrompt
    const secondStart = client.requests.findLast((request) => request.method === "turn/start")
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

    await run(created!.handle.setConfigOption("effort", "xhigh"))
    await run(created!.handle.setConfigOption("model", "gpt-5.5"))
    const turnRequested = client.nextRequest("turn/start")
    const promptPromise = run(created!.handle.prompt("go"))
    await turnRequested
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
      const turnRequested = client.nextRequest("turn/start")
      const promptPromise = run(created!.handle.prompt(text))
      await turnRequested
      client.emit("turn/completed", {
        threadId: "thread-new",
        turn: { id: turnId, status: "completed" }
      })
      await promptPromise
    }
    const lastTurnStart = (): Record<string, unknown> =>
      recordOf(client.requests.findLast((request) => request.method === "turn/start")?.params)

    await run(created!.handle.setConfigOption("speed", "fast"))
    expect(events.at(-1)?.payload).toMatchObject({ configId: "speed", value: "fast" })
    await runTurn("go fast", "t1")
    expect(lastTurnStart()).toMatchObject({ serviceTier: "priority" })

    await run(created!.handle.setConfigOption("speed", "standard"))
    await runTurn("go normal", "t2")
    expect(lastTurnStart()).toMatchObject({ serviceTier: "default" })

    await run(created!.handle.setConfigOption("model", "gpt-5.5"))
    expect(payloadOf(events.at(-1)).configOptions).not.toContainEqual(
      expect.objectContaining({ id: "speed" })
    )
    await runTurn("go", "t3")
    expect("serviceTier" in lastTurnStart()).toBe(false)
  })

  it("interrupts: turn/interrupt is sent and the turn ends cancelled", async () => {
    const { client, created, events, nextEvent } = await setup()
    const turnRequested = client.nextRequest("turn/start")
    const promptPromise = run(created!.handle.prompt("long work"))
    await turnRequested
    const started = nextEvent(
      (event) =>
        event.kind === "session.updated" &&
        payloadField(event, "turnState") === "started" &&
        payloadField(event, "turnId") === "turn-9"
    )
    client.emit("turn/started", {
      threadId: "thread-new",
      turn: { id: "turn-9", status: "inProgress" }
    })
    await started

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

  it("steers the active turn by id and declines once it has ended", async () => {
    const { client, created, nextEvent } = await setup()
    const steer = created!.handle.steer
    if (steer === undefined) throw new Error("Codex sessions steer")
    await expect(run(steer("too early"))).resolves.toBe(false)

    const turnRequested = client.nextRequest("turn/start")
    const promptPromise = run(created!.handle.prompt("long work"))
    await turnRequested
    const started = nextEvent(
      (event) => event.kind === "session.updated" && payloadField(event, "turnState") === "started"
    )
    client.emit("turn/started", { threadId: "thread-new", turn: { id: "turn-4" } })
    await started

    await expect(run(steer("and this"))).resolves.toBe(true)
    expect(client.requests.at(-1)).toMatchObject({
      method: "turn/steer",
      params: { expectedTurnId: "turn-4", threadId: "thread-new" }
    })
    client.emit("turn/completed", {
      threadId: "thread-new",
      turn: { id: "turn-4", status: "completed" }
    })
    await promptPromise
    await expect(run(steer("late"))).resolves.toBe(false)
  })

  it("applies model/effort overrides as sticky turn/start params", async () => {
    const { client, created } = await setup()
    await run(created!.handle.setConfigOption("effort", "high"))
    const turnRequested = client.nextRequest("turn/start")
    const promptPromise = run(created!.handle.prompt("go"))
    await turnRequested
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
    const turnRequested = client.nextRequest("turn/start")
    const prompt = run(created!.handle.prompt("hello"))
    await turnRequested
    client.emit("turn/started", { threadId: "thread-new", turn: { id: "turn-close" } })
    await run(created!.handle.close)
    await expect(prompt).resolves.toMatchObject({ stopReason: "cancelled" })
    expect(client.closed).toBe(true)
    expect(events.every((event) => event.kind !== "session.error")).toBe(true)
  })
})
