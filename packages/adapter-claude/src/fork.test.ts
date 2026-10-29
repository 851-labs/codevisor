import { afterEach, describe, expect, it, vi } from "vitest"

import {
  definition,
  FakeQuery,
  initMessage,
  makeProvider,
  run,
  streamEvent
} from "./test-support.js"

const STREAM_RECOVERY_BACKOFF_MS = 1_000

afterEach(() => {
  vi.useRealTimers()
})

describe("Claude forks", () => {
  it("starts a fork as a new session that resumes the source with forkSession", async () => {
    const fake = new FakeQuery()
    const forking = run(
      makeProvider(fake).createSession(definition, "/tmp", async () => {}, undefined, undefined, {
        forkFrom: "source-session"
      })
    )
    fake.push(initMessage("source-session"))
    const forked = await forking

    expect(forked.metadata.sessionId).not.toBe("source-session")
    expect(fake.options).toMatchObject({
      extraArgs: { "session-id": forked.metadata.sessionId },
      forkSession: true,
      resume: "source-session"
    })
  })

  it("recovers a forked session's stream by resuming the fork, not forking again", async () => {
    vi.useFakeTimers()
    const fake = new FakeQuery()
    const resumed = new FakeQuery()
    fake.successors.push(resumed)
    const forking = run(
      makeProvider(fake).createSession(definition, "/tmp", async () => {}, undefined, undefined, {
        forkFrom: "source-session"
      })
    )
    fake.push(initMessage("source-session"))
    const forked = await forking

    void run(forked.handle.prompt("keep going"))
    await fake.nextPrompt()
    fake.push(
      streamEvent({
        content_block: { id: "tool-x", name: "Bash", type: "tool_use" },
        index: 0,
        type: "content_block_start"
      })
    )
    await fake.drain()
    fake.finish()
    await vi.advanceTimersByTimeAsync(STREAM_RECOVERY_BACKOFF_MS)
    await resumed.nextPrompt()

    expect(resumed.options?.resume).toBe(forked.metadata.sessionId)
    expect(resumed.options).not.toHaveProperty("forkSession")
  })
})
