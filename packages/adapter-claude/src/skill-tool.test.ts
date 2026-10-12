import type { RuntimeEvent } from "@codevisor/agent-runtime"
import { describe, expect, it } from "vitest"

import {
  definition,
  FakeQuery,
  initMessage,
  makeProvider,
  resultMessage,
  run
} from "./test-support.js"

const skillUse = (id: string, input: unknown) => ({ id, input, name: "Skill", type: "tool_use" })

const assistant = (content: ReadonlyArray<unknown>, parent: string | null = null) =>
  ({
    message: { content, id: `msg-${Math.random()}`, role: "assistant" },
    parent_tool_use_id: parent,
    session_id: "sdk-session-1",
    type: "assistant"
  }) as never

const toolResult = (id: string, text: string, isError = false) =>
  ({
    message: {
      content: [{ content: text, is_error: isError, tool_use_id: id, type: "tool_result" }],
      role: "user"
    },
    parent_tool_use_id: null,
    session_id: "sdk-session-1",
    type: "user"
  }) as never

const skill = (name: string, ok = true) => ({ codevisorSkill: { name, ok } })

/// What Claude Code sends after a loaded skill's result: its instructions.
const synthetic = (text: string) =>
  ({
    isSynthetic: true,
    message: { content: [{ text, type: "text" }], role: "user" },
    parent_tool_use_id: null,
    session_id: "sdk-session-1",
    type: "user"
  }) as never

const turn = async (messages: ReadonlyArray<never>) => {
  const fake = new FakeQuery()
  const events: Array<RuntimeEvent> = []
  const created = run(
    makeProvider(fake).createSession(definition, "/tmp", async (event) => {
      events.push(event)
    })
  )
  fake.push(initMessage())
  const { handle } = await created
  const prompt = run(handle.prompt("load some skills"))
  await fake.nextPrompt()
  for (const message of messages) fake.push(message)
  fake.push(resultMessage())
  await prompt
  return events
    .map((event) => event.payload as Record<string, unknown>)
    .filter((payload) => payload.sessionUpdate === "tool_call_update")
}

describe("Claude Code's Skill tool", () => {
  it("reads like a Codevisor skill read: annotated, with the skill's instructions as output", async () => {
    const updates = await turn([
      assistant([
        skillUse("sk-1", { skill: "tophat", args: "check it" }),
        skillUse("sk-2", { skill: "plugin:review" })
      ]),
      toolResult("sk-1", "Launching skill: tophat"),
      toolResult("sk-2", "Launching skill: review"),
      // Instructions arrive matched by folder, not order, and without the
      // base-directory line Claude Code prefixes them with.
      synthetic(
        "Base directory for this skill: /repo/.claude/skills/review\n\n# Review\n\nRead it."
      ),
      synthetic("Base directory for this skill: /repo/.claude/skills/tophat\n\n# Tophat\n\nRun it.")
    ])
    expect(updates).toContainEqual(
      expect.objectContaining({ toolCallId: "sk-1", title: "Skill", _meta: skill("tophat") })
    )
    expect(updates).toContainEqual(
      expect.objectContaining({
        toolCallId: "sk-1",
        status: "completed",
        rawOutput: "Launching skill: tophat",
        _meta: skill("tophat")
      })
    )
    expect(updates).toContainEqual({
      _meta: skill("plugin:review"),
      content: [{ type: "content", content: { type: "text", text: "# Review\n\nRead it." } }],
      rawOutput: "# Review\n\nRead it.",
      sessionUpdate: "tool_call_update",
      toolCallId: "sk-2"
    })
    expect(updates).toContainEqual(
      expect.objectContaining({ toolCallId: "sk-1", rawOutput: "# Tophat\n\nRun it." })
    )
  })

  it("leaves failed, unnamed, and other synthetic messages alone", async () => {
    const updates = await turn([
      assistant([skillUse("sk-bad", { skill: "nope" }), skillUse("sk-odd", {})]),
      toolResult("sk-bad", "Unknown skill: nope", true),
      toolResult("sk-odd", "Launching skill"),
      // Nothing awaits instructions: consumed without an update.
      synthetic("Base directory for this skill: /repo/.claude/skills/nope\n\n# Nope"),
      synthetic("Base directory for this skill:"),
      // Not a skill's instructions: ordinary handling.
      synthetic("Some other reminder")
    ])
    expect(updates).toContainEqual(
      expect.objectContaining({
        toolCallId: "sk-bad",
        status: "failed",
        _meta: { codevisorSkill: { name: "nope", ok: false } }
      })
    )
    expect(updates.filter((update) => update.toolCallId === "sk-odd")).toSatisfy(
      (rows: ReadonlyArray<Record<string, unknown>>) => rows.every((row) => row._meta === undefined)
    )
    expect(updates.some((update) => update.content !== undefined)).toBe(false)
  })

  it("attaches a subagent's skill to its own thread, and the oldest waiting call when names differ", async () => {
    const updates = await turn([
      assistant([skillUse("sub-sk", { skill: "deploy" })], "agent-1"),
      toolResult("sub-sk", "Launching skill: deploy"),
      {
        isSynthetic: true,
        message: {
          content: [
            { text: "Base directory for this skill: /elsewhere/renamed\n\n# Deploy", type: "text" },
            { source: { data: "", media_type: "image/png", type: "base64" }, type: "image" }
          ],
          role: "user"
        },
        parent_tool_use_id: null,
        session_id: "sdk-session-1",
        type: "user"
      } as never
    ])
    expect(updates).toContainEqual(
      expect.objectContaining({
        toolCallId: "sub-sk",
        parentToolCallId: "agent-1",
        rawOutput: "# Deploy",
        _meta: { codevisorSkill: { name: "deploy", ok: true } }
      })
    )
  })
})
