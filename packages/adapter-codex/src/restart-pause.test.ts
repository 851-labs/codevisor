import { describe, expect, it } from "vitest"

import { payloadField, run, setup } from "./test-support.js"

const runningTurn = async () => {
  const fixture = await setup()
  const { client, created, nextEvent } = fixture
  const turnRequested = client.nextRequest("turn/start")
  const prompt = run(created!.handle.prompt("long work"))
  await turnRequested
  const started = nextEvent(
    (event) => event.kind === "session.updated" && payloadField(event, "turnState") === "started"
  )
  client.emit("turn/started", { threadId: "thread-new", turn: { id: "turn-9" } })
  await started
  return { ...fixture, prompt }
}

const turnEnd = (fixture: Awaited<ReturnType<typeof setup>>) =>
  fixture.nextEvent(
    (event) => event.kind === "session.updated" && payloadField(event, "turnState") === "ended"
  )

describe("pausing Codex for a Codevisor restart", () => {
  it("kills the app-server instead of interrupting, so Codex doesn't record a user interrupt", async () => {
    const fixture = await runningTurn()
    const { client, created, events, prompt } = fixture
    const ended = turnEnd(fixture)

    await expect(run(created!.handle.pauseForRestart!)).resolves.toEqual({
      runtimeState: "retire",
      resumesInterruptedTurn: true
    })

    expect(payloadField(await ended, "stopReason")).toBe("cancelled")
    await expect(prompt).resolves.toEqual({ stopReason: "cancelled" })
    expect(client.killed).toBe(true)
    expect(client.requests.map(({ method }) => method)).not.toContain("turn/interrupt")
    expect(events.every((event) => event.kind !== "session.error")).toBe(true)
  })

  it("interrupts like a cancel when it can't kill the app-server", async () => {
    const { client, created } = await runningTurn()
    Reflect.deleteProperty(client, "killAndWait")

    await expect(run(created!.handle.pauseForRestart!)).resolves.toEqual({
      runtimeState: "reusable"
    })
    expect(client.requests.at(-1)).toMatchObject({
      method: "turn/interrupt",
      params: { threadId: "thread-new", turnId: "turn-9" }
    })
  })

  it("leaves an idle session alone", async () => {
    const { client, created } = await setup()

    await expect(run(created!.handle.pauseForRestart!)).resolves.toEqual({
      runtimeState: "reusable"
    })
    expect(client.killed).toBe(false)
  })
})

const notice = "You were paused while Codevisor updated."

const turnStarts = (fixture: Awaited<ReturnType<typeof setup>>) =>
  fixture.client.requests.filter(({ method }) => method === "turn/start")

describe("resuming a Codex turn a restart interrupted", () => {
  it("starts a turn with no new input once the thread is resumed", async () => {
    const fixture = await setup({
      resume: "thread-paused",
      resumeInterruptedTurn: { notice, stoppedTasks: [] }
    })

    expect(turnStarts(fixture)).toEqual([
      expect.objectContaining({ params: expect.objectContaining({ input: [] }) })
    ])
  })

  it("sends the notice when the restart stopped background tasks", async () => {
    const fixture = await setup({
      resume: "thread-paused",
      resumeInterruptedTurn: { notice, stoppedTasks: ["npm run dev"] }
    })

    expect(turnStarts(fixture)).toEqual([
      expect.objectContaining({
        params: expect.objectContaining({ input: [expect.objectContaining({ text: notice })] })
      })
    ])
  })

  it("doesn't start a turn for a brand-new thread", async () => {
    const fixture = await setup({ resumeInterruptedTurn: { notice, stoppedTasks: [] } })

    expect(turnStarts(fixture)).toEqual([])
  })
})
