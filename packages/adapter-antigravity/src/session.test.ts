import { afterEach, describe, expect, it, vi } from "vitest"

import { parseModels } from "./models.js"
import { record, SIGN_IN_DETAIL } from "./protocol.js"
import { startAgyChat, type AgyChatOptions } from "./session.js"
import {
  CONVERSATION,
  fakeConnector,
  MODELS_OUTPUT,
  recorder,
  type FakeAgyProcess
} from "./test-support.js"

const models = parseModels(MODELS_OUTPUT)

const individualQuota =
  "API error (attempt 1): RESOURCE_EXHAUSTED (code 429): Individual quota reached. Please upgrade your subscription to increase your limits. Resets in 7m11s."

const resourceExhausted =
  "API error (attempt 1): RESOURCE_EXHAUSTED (code 429): Resource has been exhausted. Resets in 20s."

const capacityExhausted =
  "API error (attempt 1): MODEL_CAPACITY_EXHAUSTED (code 429): No capacity available for model. Resets in 30s."

const start = async (
  options: Partial<AgyChatOptions> = {},
  opens?: (process: FakeAgyProcess, index: number) => void
) => {
  const agy = fakeConnector(opens)
  const events = recorder()
  const chat = await startAgyChat(events.emit, {
    connector: agy.connector,
    command: "/bin/agy",
    cwd: "/repo",
    env: { HOME: "/home/me" },
    models,
    ...options
  })
  return { agy, chat, events, first: agy.processes[0]! }
}

const turnStates = (updates: ReadonlyArray<Record<string, unknown>>) =>
  updates.filter((update) => "turnState" in update)

afterEach(() => {
  vi.useRealTimers()
})

describe("Antigravity chat", () => {
  it("runs agy headless with full access on the chosen model's variant", async () => {
    const { chat, first } = await start({ extraArgs: ["--gemini_dir=/profile/gemini"] })
    expect(first.request).toEqual({
      command: "/bin/agy",
      args: [
        "--input-format=stream-json",
        "--output-format=stream-json",
        "--print-timeout=0",
        "--dangerously-skip-permissions",
        "--add-dir",
        "/repo",
        "--model",
        "gemini-4-argon-medium",
        "--gemini_dir=/profile/gemini"
      ],
      cwd: "/repo",
      env: { HOME: "/home/me" }
    })
    expect(chat.key).toBe(CONVERSATION)
    expect(chat.configOptions()).toEqual([
      {
        id: "model",
        name: "Model",
        category: "model",
        currentValue: "gemini-4-argon",
        options: [
          { value: "gemini-4-argon", name: "Gemini 4 Argon" },
          { value: "gemini-3.8-flash", name: "Gemini 3.8 Flash" },
          { value: "gpt-oss-120b", name: "GPT-OSS 120B" }
        ]
      },
      {
        id: "thought_level",
        name: "Reasoning",
        category: "thought_level",
        currentValue: "medium",
        options: [
          { value: "high", name: "High" },
          { value: "medium", name: "Medium" }
        ]
      }
    ])
  })

  it("resumes a conversation, and leaves the model to agy when none could be listed", async () => {
    const { chat, first } = await start({ resume: "c-old", models: [] }, (process) =>
      process.init("c-old")
    )
    expect(first.request.args.slice(-2)).toEqual(["--conversation", "c-old"])
    expect(first.request.args).not.toContain("--model")
    expect(chat.key).toBe("c-old")
    expect(chat.configOptions()).toEqual([])
  })

  it("keeps the resumed conversation when agy's init doesn't name one", async () => {
    const { chat, events } = await start({ resume: "c-old" }, (process) => {
      process.step({ step_index: 0, step_type: "agent_response", text_delta: "early" })
      process.emit({ event: "init" })
    })
    expect(chat.key).toBe("c-old")
    expect(events.outputs()).toEqual([])
  })

  it("streams a turn's reply, sends attachments as file notes, and ends on agy's result", async () => {
    const { chat, events, first } = await start()
    const done = chat.prompt({
      text: "What's in this?",
      attachments: [
        {
          name: "shot.png",
          mimeType: "image/png",
          kind: "image",
          sizeBytes: 3,
          path: "/tmp/shot.png"
        }
      ]
    })
    await first.sends()
    expect(first.sent[0]).toEqual({
      event: "user",
      message: {
        content: "What's in this?\n\n[Attached file: /tmp/shot.png (shot.png, image/png)]"
      }
    })
    first.step({ step_index: 0, step_type: "user_input" })
    first.step({ step_index: 1, step_type: "agent_response", state: "ACTIVE", text_delta: "A cat" })
    first.result({
      usage: { input_tokens: 90, output_tokens: 10, cache_read_tokens: 40, total_tokens: 100 }
    })
    await expect(done).resolves.toEqual({ stopReason: "end_turn" })
    expect(events.outputs()).toEqual([
      {
        sessionUpdate: "agent_message_chunk",
        messageId: `${CONVERSATION}:1`,
        content: { type: "text", text: "A cat" }
      }
    ])
    const updates = events.updates()
    expect(updates).toContainEqual({
      sessionUpdate: "usage_update",
      inputTokens: 90,
      outputTokens: 10,
      totalTokens: 100,
      cachedInputTokens: 40
    })
    const [started, ended] = turnStates(updates)
    expect(started).toMatchObject({ initiatedBy: "user", turnState: "started" })
    expect(ended).toEqual({
      initiatedBy: "user",
      stopReason: "end_turn",
      turnId: started!.turnId,
      turnState: "ended"
    })
  })

  it("holds a prompt sent mid-turn until agy has answered the one before it", async () => {
    const { chat, first } = await start()
    const one = chat.prompt("first")
    const two = chat.prompt("second")
    await first.sends(1)
    first.result()
    await one
    await first.sends(2)
    expect(first.sent.map((line) => record(line.message).content)).toEqual(["first", "second"])
    first.result()
    await expect(two).resolves.toEqual({ stopReason: "end_turn" })
  })

  it.each<
    [
      Record<string, unknown>,
      { stopReason: string; stopDetail?: string; stopKind?: string; resetsAt?: string }
    ]
  >([
    [
      { status: "ERROR", error: "model capacity exhausted" },
      { stopReason: "end_turn", stopDetail: "model capacity exhausted" }
    ],
    [
      { status: "ERROR", error: individualQuota },
      {
        stopReason: "end_turn",
        stopDetail: individualQuota,
        stopKind: "usageLimit",
        resetsAt: "2026-10-20T12:07:11.000Z"
      }
    ],
    [
      { status: "ERROR", error: "Your AI credits balance is too low to continue." },
      {
        stopReason: "end_turn",
        stopDetail: "Your AI credits balance is too low to continue.",
        stopKind: "usageLimit"
      }
    ],
    [
      { status: "ERROR", error: "Rate limit exceeded. Resets in 20s." },
      { stopReason: "end_turn", stopDetail: "Rate limit exceeded. Resets in 20s." }
    ],
    [
      { status: "ERROR", error: capacityExhausted },
      { stopReason: "end_turn", stopDetail: capacityExhausted }
    ],
    [
      { status: "ERROR", error: resourceExhausted },
      { stopReason: "end_turn", stopDetail: resourceExhausted }
    ],
    [
      { status: "ERROR", error: "authentication failed or timed out" },
      { stopReason: "end_turn", stopDetail: SIGN_IN_DETAIL, stopKind: "authRequired" }
    ],
    [
      { status: "ERROR" },
      { stopReason: "end_turn", stopDetail: "Antigravity stopped with an error." }
    ],
    [
      {
        denied_actions: [{ action: "command", display_name: "RunCommand" }, { action: "url" }, {}]
      },
      {
        stopReason: "end_turn",
        stopDetail: "Antigravity skipped actions it needed permission for: RunCommand, url."
      }
    ],
    [{ status: "CANCELED" }, { stopReason: "cancelled" }]
  ])("ends a turn agy reports as %j", async (result, ending) => {
    vi.useFakeTimers({ toFake: ["Date"] })
    vi.setSystemTime(new Date("2026-10-20T12:00:00.000Z"))
    const { chat, events, first } = await start()
    const done = chat.prompt("go")
    await first.sends()
    first.result(result)
    await expect(done).resolves.toEqual({ stopReason: ending.stopReason })
    const ended = turnStates(events.updates()).at(-1)!
    expect(ended.stopReason).toBe(ending.stopReason)
    expect(ended.stopDetail).toBe(ending.stopDetail)
    expect(ended.stopKind).toBe(ending.stopKind)
    expect(ended.resetsAt).toBe(ending.resetsAt)
  })

  it("can't start without a sign-in, and says so", async () => {
    await expect(
      start({}, (process) =>
        process.result({
          conversation_id: "",
          status: "ERROR",
          error: "authentication failed or timed out"
        })
      )
    ).rejects.toThrow(SIGN_IN_DETAIL)
  })

  it("reports agy exiting before it opens a conversation, and closes it", async () => {
    let started: FakeAgyProcess | undefined
    await expect(
      start({}, (process) => {
        started = process
        process.exit("agy exited: bad flag")
      })
    ).rejects.toThrow("agy exited: bad flag")
    expect(started!.closed).toBe(true)
  })

  it("gives up on an agy that never opens a conversation", async () => {
    vi.useFakeTimers()
    const agy = fakeConnector(() => undefined)
    const starting = startAgyChat(recorder().emit, {
      connector: agy.connector,
      command: "/bin/agy",
      cwd: "/repo",
      env: {},
      models,
      startDeadlineMs: 1_000
    })
    const failed = expect(starting).rejects.toThrow("Antigravity didn't start in time.")
    await vi.advanceTimersByTimeAsync(999)
    expect(agy.processes[0]!.closed).toBe(false)
    await vi.advanceTimersByTimeAsync(1)
    await failed
    expect(agy.processes[0]!.closed).toBe(true)
  })

  it("cancels with an interrupt and keeps using an agy that survives it", async () => {
    const { agy, chat, first } = await start()
    const done = chat.prompt("long task")
    await first.sends()
    await chat.cancel()
    expect(first.interrupted).toBe(1)
    first.result({ status: "INTERRUPTED" })
    await expect(done).resolves.toEqual({ stopReason: "cancelled" })
    const next = chat.prompt("again")
    await first.sends(2)
    first.result()
    await next
    expect(agy.processes).toHaveLength(1)
  })

  it("resumes the conversation in a new agy when the interrupt took the old one down", async () => {
    const { agy, chat, first } = await start()
    const done = chat.prompt("long task")
    await first.sends()
    await chat.cancel()
    first.exit()
    await expect(done).resolves.toEqual({ stopReason: "cancelled" })
    const next = chat.prompt("again")
    const second = await agy.spawned(2)
    expect(second.request.args.slice(-2)).toEqual(["--conversation", CONVERSATION])
    await second.sends()
    second.result()
    await expect(next).resolves.toEqual({ stopReason: "end_turn" })
  })

  it("stops an agy that ignores the interrupt", async () => {
    vi.useFakeTimers()
    const { chat, first } = await start({ cancelGraceMs: 1_000 })
    const done = chat.prompt("long task")
    await first.sends()
    await chat.cancel()
    await vi.advanceTimersByTimeAsync(999)
    expect(first.closed).toBe(false)
    await vi.advanceTimersByTimeAsync(1)
    await expect(done).resolves.toEqual({ stopReason: "cancelled" })
    expect(first.closed).toBe(true)
  })

  it("leaves a turn alone when the cancel grace runs out after it ended", async () => {
    vi.useFakeTimers()
    const { chat, events, first } = await start({ cancelGraceMs: 1_000 })
    const done = chat.prompt("long task")
    await first.sends()
    await chat.cancel()
    first.result({ status: "INTERRUPTED" })
    await done
    const next = chat.prompt("again")
    await first.sends(2)
    await vi.advanceTimersByTimeAsync(1_000)
    expect(first.closed).toBe(false)
    first.result()
    await next
    expect(
      turnStates(events.updates()).filter((update) => update.turnState === "ended")
    ).toHaveLength(2)
  })

  it("does nothing when cancelled between turns", async () => {
    const { chat, first } = await start()
    await chat.cancel()
    expect(first.interrupted).toBe(0)
  })

  it("ends a turn agy crashed in, and starts a fresh agy for the next prompt", async () => {
    const { agy, chat, events, first } = await start()
    const done = chat.prompt("go")
    await first.sends()
    first.exit("agy exited: panic: nil map")
    await expect(done).resolves.toEqual({ stopReason: "end_turn" })
    expect(turnStates(events.updates()).at(-1)!.stopDetail).toBe("agy exited: panic: nil map")
    first.exit()
    const next = chat.prompt("again")
    const second = await agy.spawned(2)
    await second.sends()
    second.result()
    await next
  })

  it("ends the turn with why agy couldn't be started again", async () => {
    const { chat, events, first } = await start({}, (process, index) => {
      if (index === 0) process.init()
      else process.result({ status: "ERROR", error: "authentication failed or timed out" })
    })
    first.exit()
    await expect(chat.prompt("go")).resolves.toEqual({ stopReason: "end_turn" })
    expect(turnStates(events.updates()).at(-1)).toMatchObject({
      stopDetail: SIGN_IN_DETAIL,
      stopKind: "authRequired"
    })
  })

  it("switches model and reasoning on the next prompt, keeping the conversation", async () => {
    const { agy, chat, first } = await start()
    expect(
      (await chat.setConfigOption("model", "gemini-3.8-flash")).map((option) => option.currentValue)
    ).toEqual(["gemini-3.8-flash"])
    const done = chat.prompt("go")
    const second = await agy.spawned(2)
    expect(first.closed).toBe(true)
    expect(second.request.args).toEqual(
      expect.arrayContaining(["--model", "gemini-3.8-flash-medium", "--conversation", CONVERSATION])
    )
    await second.sends()
    second.result()
    await done

    await chat.setConfigOption("model", "gemini-4-argon")
    await chat.setConfigOption("thought_level", "high")
    const again = chat.prompt("go")
    const third = await agy.spawned(3)
    expect(third.request.args).toContain("gemini-4-argon-high")
    await third.sends()
    third.result()
    await again
  })

  it("keeps the running agy when a setting doesn't change", async () => {
    const { agy, chat, first } = await start()
    await chat.setConfigOption("model", "gemini-4-argon")
    await chat.setConfigOption("thought_level", "medium")
    const done = chat.prompt("go")
    await first.sends()
    first.result()
    await done
    expect(agy.processes).toHaveLength(1)
  })

  it("refuses settings agy doesn't have", async () => {
    const { chat } = await start()
    await expect(chat.setConfigOption("model", "nope")).rejects.toThrow("Unknown model: nope")
    await expect(chat.setConfigOption("thought_level", "max")).rejects.toThrow(
      "Unknown reasoning level: max"
    )
    await expect(chat.setConfigOption("mode", "plan")).rejects.toThrow(
      "Antigravity has no setting named mode"
    )
    const unlisted = await start({ models: [] })
    await expect(unlisted.chat.setConfigOption("thought_level", "high")).rejects.toThrow(
      "Unknown reasoning level: high"
    )
  })

  it("ends a running turn as cancelled when the chat closes", async () => {
    const { chat, first } = await start()
    const done = chat.prompt("go")
    await first.sends()
    chat.close()
    await expect(done).resolves.toEqual({ stopReason: "cancelled" })
    expect(first.closed).toBe(true)
  })

  it("ignores steps it can't place and events it doesn't know", async () => {
    const { chat, events, first } = await start()
    const done = chat.prompt("go")
    await first.sends()
    first.emit({ event: "step_update", step_update: { step_type: "agent_response" } })
    first.emit({ event: "future_thing" })
    first.result()
    await done
    expect(events.outputs()).toEqual([])
  })
})
