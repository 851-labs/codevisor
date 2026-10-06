import { describe, expect, it } from "vitest"

import { makeMessagePhases } from "./message-phases.js"
import type { RuntimeEvent } from "./types.js"

const output = (payload: Record<string, unknown>): RuntimeEvent => ({
  kind: "session.output",
  subjectId: "s",
  payload
})
const text = (value: string, extra: Record<string, unknown> = {}) =>
  output({ sessionUpdate: "agent_message_chunk", content: { type: "text", text: value }, ...extra })
const tool = (id: string, extra: Record<string, unknown> = {}) =>
  output({ sessionUpdate: "tool_call", toolCallId: id, ...extra })
const turn = (turnState: string): RuntimeEvent => ({
  kind: "session.updated",
  subjectId: "s",
  payload: { turnState }
})
const commentary = (messageId: string) =>
  output({
    content: { text: "", type: "text" },
    messageId,
    phase: "commentary",
    sessionUpdate: "agent_message_chunk"
  })

/// Labels a stream, returning what the sink receives.
const label = (events: ReadonlyArray<RuntimeEvent>) => {
  let next = 0
  const phases = makeMessagePhases(() => `run-${++next}`)
  return events.flatMap((event) => phases.label(event))
}

describe("message phases", () => {
  it("demotes text to commentary once a tool call follows it, and leaves the answer alone", () => {
    expect(
      label([
        text("I'll check.", { messageId: "a" }),
        tool("t1"),
        output({ sessionUpdate: "tool_call_update", toolCallId: "t1", status: "completed" }),
        tool("t2"),
        text("Here it is.", { messageId: "b" })
      ])
    ).toEqual([
      text("I'll check.", { messageId: "a" }),
      commentary("a"),
      tool("t1"),
      output({ sessionUpdate: "tool_call_update", toolCallId: "t1", status: "completed" }),
      tool("t2"),
      text("Here it is.", { messageId: "b" })
    ])
  })

  it("gives ID-less text one ID per run, so it can be demoted too", () => {
    expect(label([text(""), text("Let me "), text("look."), tool("t1"), text("Done.")])).toEqual([
      text(""),
      text("Let me ", { messageId: "run-1" }),
      text("look.", { messageId: "run-1" }),
      commentary("run-1"),
      tool("t1"),
      text("Done.", { messageId: "run-2" })
    ])
    // Any other update ends a run, as it ends the transcript's text span.
    expect(
      label([
        text("One"),
        output({ sessionUpdate: "agent_thought_chunk", content: { type: "text", text: "…" } }),
        text("Two"),
        text("Three", { messageId: "x" }),
        text("Four")
      ]).map((event) => (event.payload as { messageId?: string }).messageId)
    ).toEqual(["run-1", undefined, "run-2", "x", "run-3"])
  })

  it("leaves text an adapter labels itself to the adapter", () => {
    expect(
      label([
        text("Plan", { messageId: "a" }),
        commentary("a"),
        tool("t1"),
        text("Answer", { messageId: "b", phase: "final" }),
        tool("t2")
      ])
    ).toEqual([
      text("Plan", { messageId: "a" }),
      commentary("a"),
      tool("t1"),
      text("Answer", { messageId: "b", phase: "final" }),
      tool("t2")
    ])
  })

  it("makes a demoted span the answer again when it goes on after the tool call", () => {
    expect(
      label([
        text("Checking", { messageId: "a" }),
        tool("t1"),
        text("", { messageId: "a" }),
        text(" — found it.", { messageId: "a" }),
        tool("t2")
      ])
    ).toEqual([
      text("Checking", { messageId: "a" }),
      commentary("a"),
      tool("t1"),
      text("", { messageId: "a" }),
      text(" — found it.", { messageId: "a", phase: "final" }),
      commentary("a"),
      tool("t2")
    ])
  })

  it("ignores subagents, and never reaches back into an earlier turn", () => {
    expect(
      label([
        text("Sub", { messageId: "s1", parentToolCallId: "agent" }),
        tool("t1", { parentToolCallId: "agent" }),
        text("Answer", { messageId: "a" }),
        turn("ended"),
        turn("started"),
        tool("t2"),
        { kind: "session.output", subjectId: "s", payload: "opaque" },
        { kind: "session.error", subjectId: "s", payload: { message: "x" } }
      ])
    ).toEqual([
      text("Sub", { messageId: "s1", parentToolCallId: "agent" }),
      tool("t1", { parentToolCallId: "agent" }),
      text("Answer", { messageId: "a" }),
      turn("ended"),
      turn("started"),
      tool("t2"),
      { kind: "session.output", subjectId: "s", payload: "opaque" },
      { kind: "session.error", subjectId: "s", payload: { message: "x" } }
    ])
    // Other session updates don't end a turn.
    expect(
      label([
        text("Checking", { messageId: "a" }),
        { kind: "session.updated", subjectId: "s", payload: { title: "Flights" } },
        tool("t1")
      ])
    ).toContainEqual(commentary("a"))
  })

  it("passes non-text chunks through untouched", () => {
    const image = output({ sessionUpdate: "agent_message_chunk", content: { type: "image" } })
    const bare = output({ sessionUpdate: "agent_message_chunk", content: { type: "text" } })
    expect(label([image, bare, tool("t1")])).toEqual([image, bare, tool("t1")])
  })

  it("gives ID-less text a unique ID by default", () => {
    const phases = makeMessagePhases()
    const [first] = phases.label(text("Hi")) as [RuntimeEvent]
    expect((first.payload as { messageId?: string }).messageId).toMatch(/^[0-9a-f-]{36}$/)
  })
})
