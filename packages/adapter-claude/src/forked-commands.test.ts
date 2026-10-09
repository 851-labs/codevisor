import type { SDKMessage } from "@anthropic-ai/claude-agent-sdk"
import type { RuntimeEvent } from "@codevisor/agent-runtime"
import { afterEach, describe, expect, it, vi } from "vitest"

import type { SubagentTranscripts } from "./subagent-transcripts.js"
import {
  definition,
  FakeQuery,
  initMessage,
  makeProvider,
  resultMessage,
  run,
  streamEvent,
  systemMessage
} from "./test-support.js"

const FORK = "forked-command-code-review"
const SKILL_PROMPT = "Review the diff. Report at most 4 findings."

const forkMessage = (type: "assistant" | "user", content: Array<unknown>): SDKMessage =>
  ({
    message: { content, role: type },
    parent_tool_use_id: FORK,
    session_id: "sdk-session-1",
    type
  }) as never

// A reply the CLI writes itself: never streamed, so no `message_start`.
const syntheticReply = (text: string): SDKMessage =>
  ({
    message: {
      content: [{ text, type: "text" }],
      id: "9d9fe63e-4752-4dcc-882f-c150c6673467",
      model: "<synthetic>",
      role: "assistant"
    },
    parent_tool_use_id: null,
    session_id: "sdk-session-1",
    type: "assistant"
  }) as never

const BASH_CALL = {
  id: "tool-1",
  input: { command: "git diff HEAD" },
  name: "Bash",
  type: "tool_use"
}
const BASH_RESULT = { content: "diff", is_error: false, tool_use_id: "tool-1", type: "tool_result" }

const forkStarted = systemMessage("task_started", {
  description: "/code-review",
  prompt: SKILL_PROMPT,
  subagent_type: "general-purpose",
  task_id: "task-1",
  task_type: "local_agent"
})

const forkEnded = (status: "completed" | "failed"): SDKMessage =>
  systemMessage("task_notification", { status, summary: "/code-review", task_id: "task-1" })

// What Claude Code 2.1.293 sends once the fork has ended: its whole thread
// (tool calls only), then the report as a reply it writes itself.
const endOfRunCopy = (report: string): Array<SDKMessage> => [
  forkMessage("user", [{ text: SKILL_PROMPT, type: "text" }]),
  forkMessage("assistant", [BASH_CALL]),
  forkMessage("user", [BASH_RESULT]),
  syntheticReply(report)
]

const codeReview = (status: "completed" | "failed", report: string): Array<SDKMessage> => [
  forkStarted,
  forkEnded(status),
  ...endOfRunCopy(report)
]

// A transcript the CLI appends to while the fork runs.
const liveTranscript = () => {
  const lines: Array<string> = []
  const transcripts: SubagentTranscripts = {
    locate: (_sessionId, agentId) =>
      agentId === "task-1" ? "/config/agent-task-1.jsonl" : undefined,
    readLines: (_path, offset) => ({
      offset: lines.length,
      text: lines
        .slice(offset)
        .map((line) => `${line}\n`)
        .join("")
    })
  }
  const write = (type: "assistant" | "user", content: unknown, id?: string): void => {
    lines.push(
      JSON.stringify({ message: { content, id, role: type }, type, uuid: `line-${lines.length}` })
    )
  }
  return { transcripts, write }
}

const startTurn = async (transcripts?: SubagentTranscripts) => {
  const fake = new FakeQuery()
  const provider = makeProvider(
    fake,
    undefined,
    undefined,
    transcripts === undefined ? {} : { subagentTranscripts: () => transcripts }
  )
  const events: Array<RuntimeEvent> = []
  const emit = async (event: RuntimeEvent): Promise<void> => {
    events.push(event)
  }
  const createPromise = run(provider.createSession(definition, "/tmp", emit))
  fake.push(initMessage())
  const created = await createPromise
  const turn = run(created.handle.prompt("/code-review low"))
  await fake.nextPrompt()
  const payloads = () => events.map((event) => event.payload as Record<string, unknown>)
  return { fake, payloads, turn }
}

const promptTurn = async (messages: Array<SDKMessage>): Promise<Array<Record<string, unknown>>> => {
  const { fake, payloads, turn } = await startTurn()
  for (const message of messages) fake.push(message)
  fake.push(resultMessage())
  await turn
  return payloads()
}

// Claude's streamed answer to the nudge sent once a forked command reports.
const CLAUDE_REPLY = "The review found nothing to fix."
const claudeReply: Array<SDKMessage> = [
  streamEvent({ message: { id: "msg-reply" }, type: "message_start" }),
  streamEvent({ content_block: { text: "", type: "text" }, index: 0, type: "content_block_start" }),
  streamEvent({
    delta: { text: CLAUDE_REPLY, type: "text_delta" },
    index: 0,
    type: "content_block_delta"
  }),
  {
    message: {
      content: [{ text: CLAUDE_REPLY, type: "text" }],
      id: "msg-reply",
      role: "assistant"
    },
    parent_tool_use_id: null,
    session_id: "sdk-session-1",
    type: "assistant"
  } as never,
  resultMessage()
]

// The forked command's turn ends; Claude is asked to answer and does.
const answerReport = async (fake: FakeQuery): Promise<void> => {
  fake.push(resultMessage())
  await fake.nextPrompt()
  for (const message of claudeReply) fake.push(message)
}

const forkUpdates = (payloads: Array<Record<string, unknown>>) =>
  payloads.filter((payload) => payload.toolCallId === FORK)

const textUnder = (payloads: Array<Record<string, unknown>>, parent: string | undefined) =>
  payloads
    .filter(
      (payload) =>
        payload.sessionUpdate === "agent_message_chunk" && payload.parentToolCallId === parent
    )
    .map((payload) => (payload.content as { text: string }).text)

const mainText = (payloads: Array<Record<string, unknown>>) => textUnder(payloads, undefined)

describe("a forked command", () => {
  afterEach(() => {
    vi.useRealTimers()
  })

  it("runs under its own agent call, then Claude answers with its report", async () => {
    const { fake, payloads: read, turn } = await startTurn()
    for (const message of codeReview("completed", "No findings.")) fake.push(message)
    await answerReport(fake)
    await turn
    const payloads = read()

    // The nudge to answer goes to Claude, not the transcript.
    expect(fake.userMessages).toHaveLength(2)
    expect(JSON.stringify(fake.userMessages[1]?.message.content)).toContain(
      "finished in a subagent"
    )

    expect(forkUpdates(payloads)).toEqual([
      {
        _meta: { codevisorSubagent: { taskId: "task-1" } },
        kind: "agent",
        rawInput: {
          description: "/code-review",
          prompt: SKILL_PROMPT,
          subagent_type: "general-purpose"
        },
        sessionUpdate: "tool_call",
        status: "in_progress",
        title: "Skill: /code-review",
        toolCallId: FORK
      },
      { sessionUpdate: "tool_call_update", status: "completed", toolCallId: FORK }
    ])
    // Its task names the row, so clients know the agent is running.
    expect(payloads).toContainEqual({
      backgroundTasks: [expect.objectContaining({ id: "task-1", toolUseId: FORK })]
    })
    expect(payloads).toContainEqual(
      expect.objectContaining({ parentToolCallId: FORK, toolCallId: "tool-1" })
    )
    // The report ends the fork's thread; Claude's answer is the turn's.
    expect(textUnder(payloads, FORK)).toEqual(["No findings."])
    expect(mainText(payloads)).toEqual([CLAUDE_REPLY])
    expect(payloads.filter((payload) => payload.turnState === "ended")).toHaveLength(1)
  })

  it("settles as failed when its task failed, showing the CLI's reply as the answer", async () => {
    const { fake, payloads: read, turn } = await startTurn()
    for (const message of codeReview("failed", "Not logged in · Please run /login")) {
      fake.push(message)
    }
    fake.push(resultMessage())
    await turn
    const payloads = read()

    expect(fake.userMessages).toHaveLength(1)

    expect(forkUpdates(payloads).at(-1)).toEqual({
      sessionUpdate: "tool_call_update",
      status: "failed",
      toolCallId: FORK
    })
    expect(mainText(payloads)).toEqual(["Not logged in · Please run /login"])
  })

  it("shows its thread live from the transcript, without repeating it at the end", async () => {
    vi.useFakeTimers({ toFake: ["setInterval", "clearInterval"] })
    const transcript = liveTranscript()
    const { fake, payloads, turn } = await startTurn(transcript.transcripts)
    fake.push(forkStarted)
    await fake.drain()
    transcript.write("user", SKILL_PROMPT)
    transcript.write("assistant", [BASH_CALL], "msg-1")

    await vi.advanceTimersByTimeAsync(500)

    // The CLI has sent nothing of the thread yet.
    expect(payloads()).toContainEqual(
      expect.objectContaining({
        parentToolCallId: FORK,
        status: "in_progress",
        toolCallId: "tool-1"
      })
    )

    transcript.write("user", [BASH_RESULT])
    transcript.write("assistant", [{ text: "No findings.", type: "text" }], "msg-2")
    for (const message of [forkEnded("completed"), ...endOfRunCopy("No findings.")]) {
      fake.push(message)
    }
    await answerReport(fake)
    await turn

    const bashUpdates = payloads().filter((payload) => payload.toolCallId === "tool-1")
    expect(bashUpdates.map((payload) => payload.status)).toEqual(["in_progress", "completed"])
    expect(textUnder(payloads(), FORK)).toEqual(["No findings."])
    expect(mainText(payloads())).toEqual([CLAUDE_REPLY])
    expect(forkUpdates(payloads()).at(-1)).toEqual({
      sessionUpdate: "tool_call_update",
      status: "completed",
      toolCallId: FORK
    })
  })
})

describe("a streamed reply", () => {
  it("is not repeated by its consolidated message", async () => {
    const payloads = await promptTurn([
      streamEvent({ message: { id: "msg-1" }, type: "message_start" }),
      streamEvent({
        content_block: { text: "", type: "text" },
        index: 0,
        type: "content_block_start"
      }),
      streamEvent({
        delta: { text: "Hello.", type: "text_delta" },
        index: 0,
        type: "content_block_delta"
      }),
      {
        message: { content: [{ text: "Hello.", type: "text" }], id: "msg-1", role: "assistant" },
        parent_tool_use_id: null,
        session_id: "sdk-session-1",
        type: "assistant"
      } as never
    ])

    expect(mainText(payloads)).toEqual(["Hello."])
  })
})
