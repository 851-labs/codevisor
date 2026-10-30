import type { InterruptedTurnResume } from "@codevisor/agent-runtime"
import { afterEach, describe, expect, it, vi } from "vitest"

import {
  definition,
  FakeQuery,
  initMessage,
  makeProvider,
  resultMessage,
  run,
  streamEvent
} from "./test-support.js"

const STREAM_RECOVERY_BACKOFF_MS = 1_000
const resumingVersion = async () => "2.1.311"
const notice: InterruptedTurnResume = {
  notice: "You were paused while Codevisor updated.",
  stoppedTasks: []
}
const resumeEnvKeys = [
  "CLAUDE_CODE_RESUME_INTERRUPTED_TURN",
  "CLAUDE_CODE_RESUME_PROMPT",
  "CLAUDE_CODE_RESUME_REASON"
]

const runningTurn = async (checkVersion: () => Promise<string>) => {
  const fake = new FakeQuery()
  const started = run(
    makeProvider(fake, checkVersion).createSession(definition, "/tmp", async () => undefined)
  )
  fake.push(initMessage())
  const created = await started
  const prompt = run(created.handle.prompt("do work"))
  await fake.nextPrompt()
  fake.push(
    streamEvent({
      content_block: { id: "tool-1", name: "Bash", type: "tool_use" },
      index: 0,
      type: "content_block_start"
    })
  )
  await fake.drain()
  return { fake, created, prompt }
}

const resumedLaunch = async (
  checkVersion: () => Promise<string>,
  resumeInterruptedTurn?: InterruptedTurnResume
) => {
  const fake = new FakeQuery()
  await run(
    makeProvider(fake, checkVersion).loadSession(
      definition,
      "paused-session",
      "/tmp",
      async () => undefined,
      undefined,
      undefined,
      resumeInterruptedTurn === undefined ? undefined : { resumeInterruptedTurn }
    )
  )
  return fake
}

describe("pausing Claude for a Codevisor restart", () => {
  afterEach(() => {
    vi.useRealTimers()
  })

  it("ends the Claude session instead of interrupting, so the turn reads as cut short by a shutdown", async () => {
    const { fake, created, prompt } = await runningTurn(resumingVersion)

    const pause = run(created.handle.pauseForRestart!)
    await fake.waitFor(() => fake.controlRequests.length === 1)
    fake.push(resultMessage("error_during_execution"))

    await expect(pause).resolves.toEqual({ runtimeState: "retire", resumesInterruptedTurn: true })
    await expect(prompt).resolves.toMatchObject({ stopReason: "cancelled" })
    expect(fake.controlRequests).toEqual([{ reason: "host_draining", subtype: "end_session" }])
    expect(fake.interrupts).toEqual([])
  })

  it("interrupts like a cancel when Claude Code is too old to resume the turn", async () => {
    const { fake, created, prompt } = await runningTurn(async () => "2.1.310")

    const pause = run(created.handle.pauseForRestart!)
    await fake.waitFor(() => fake.interrupts.length === 1)
    fake.push(resultMessage("error_during_execution"))

    await expect(pause).resolves.toEqual({ runtimeState: "reusable" })
    await expect(prompt).resolves.toMatchObject({ stopReason: "cancelled" })
    expect(fake.controlRequests).toEqual([])
  })

  it("relaunches with Claude's interrupted-turn resume and the notice as its hidden prompt", async () => {
    const resumed = await resumedLaunch(resumingVersion, notice)
    const plain = await resumedLaunch(resumingVersion)
    const tooOld = await resumedLaunch(async () => "2.1.310", notice)

    expect(resumed.options?.env).toMatchObject({
      CLAUDE_CODE_RESUME_INTERRUPTED_TURN: "1",
      CLAUDE_CODE_RESUME_PROMPT: notice.notice,
      CLAUDE_CODE_RESUME_REASON: "host_draining"
    })
    for (const launch of [plain, tooOld]) {
      expect(Object.keys(launch.options?.env ?? {})).toEqual(
        expect.not.arrayContaining(resumeEnvKeys)
      )
    }
  })

  it("drops the interrupted-turn resume when it relaunches Claude after a stream death", async () => {
    vi.useFakeTimers()
    const fake = new FakeQuery()
    const recovered = new FakeQuery()
    fake.successors.push(recovered)
    const created = await run(
      makeProvider(fake, resumingVersion).loadSession(
        definition,
        "paused-session",
        "/tmp",
        async () => undefined,
        undefined,
        undefined,
        { resumeInterruptedTurn: notice }
      )
    )
    const prompt = run(created.handle.prompt("keep going"))
    await fake.nextPrompt()
    fake.finish()
    await vi.advanceTimersByTimeAsync(STREAM_RECOVERY_BACKOFF_MS)
    await recovered.nextPrompt()

    expect(fake.options?.env).toMatchObject({ CLAUDE_CODE_RESUME_INTERRUPTED_TURN: "1" })
    expect(Object.keys(recovered.options?.env ?? { missing: "" })).toEqual(
      expect.not.arrayContaining(resumeEnvKeys)
    )
    recovered.push(resultMessage())
    await prompt
  })
})
