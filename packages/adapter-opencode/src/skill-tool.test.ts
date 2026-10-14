import { describe, expect, it } from "vitest"

import { makeOpenCodeExtension } from "./extension.js"
import { skillReadUpdate, withSkillRead } from "./skill-tool.js"

const wrapped = [
  '<skill_content name="tophat">',
  "# Skill: tophat",
  "",
  "# Tophat",
  "",
  "Run the change.",
  "",
  "Base directory for this skill: /repo/.opencode/skill/tophat",
  "Relative paths in this skill (e.g., scripts/, reference/) are relative to this base directory.",
  "Note: file list is sampled.",
  "",
  "<skill_files>",
  "<file>/repo/.opencode/skill/tophat/notes.md</file>",
  "</skill_files>",
  "</skill_content>"
].join("\n")

const skill = (name: string, ok = true) => ({ codevisorSkill: { name, ok } })

describe("OpenCode's skill tool", () => {
  it("is annotated from its input while it runs", () => {
    expect(
      skillReadUpdate({
        sessionUpdate: "tool_call",
        toolCallId: "sk",
        title: "skill",
        kind: "other",
        status: "pending",
        rawInput: { name: "tophat" }
      })
    ).toEqual({
      sessionUpdate: "tool_call",
      toolCallId: "sk",
      title: "skill",
      kind: "other",
      status: "pending",
      rawInput: { name: "tophat" },
      _meta: skill("tophat")
    })
  })

  it("shows only the skill's instructions once loaded, named from the output's metadata", () => {
    const loaded = skillReadUpdate({
      sessionUpdate: "tool_call_update",
      toolCallId: "sk",
      status: "completed",
      title: "Loaded skill: tophat",
      content: [{ type: "content", content: { type: "text", text: wrapped } }],
      rawOutput: {
        output: wrapped,
        metadata: { name: "tophat", dir: "/repo/.opencode/skill/tophat" }
      },
      _meta: { other: true }
    })
    expect(loaded).toEqual({
      sessionUpdate: "tool_call_update",
      toolCallId: "sk",
      status: "completed",
      title: "Loaded skill: tophat",
      content: [
        { type: "content", content: { type: "text", text: "# Tophat\n\nRun the change." } }
      ],
      rawOutput: "# Tophat\n\nRun the change.",
      _meta: { other: true, ...skill("tophat") }
    })
    const bare = skillReadUpdate({
      sessionUpdate: "tool_call_update",
      status: "completed",
      rawOutput: {
        output: '<skill_content name="x">\nJust text.\n</skill_content>',
        metadata: { name: "x" }
      }
    })
    expect(bare.rawOutput).toBe("Just text.")
  })

  it("marks a failed load, and leaves every other update alone", () => {
    expect(
      skillReadUpdate({
        sessionUpdate: "tool_call_update",
        status: "failed",
        title: "skill",
        rawInput: { name: "nope" },
        rawOutput: { error: "Skill not found: nope" }
      })._meta
    ).toEqual(skill("nope", false))
    const others = [
      { sessionUpdate: "agent_message_chunk", content: { type: "text", text: "hi" } },
      { sessionUpdate: "tool_call", title: "bash", rawInput: { command: "ls" } },
      { sessionUpdate: "tool_call", title: "skill", rawInput: {} },
      { sessionUpdate: "tool_call_update", rawOutput: { output: "plain", metadata: { name: "x" } } }
    ]
    for (const update of others) expect(skillReadUpdate(update)).toBe(update)
    expect(withSkillRead({ type: "status" })).toEqual({ type: "status" })
  })

  it("rewrites the chat's own updates and its subagents'", () => {
    const events: Array<unknown> = []
    const extension = makeOpenCodeExtension({
      emit: (event: unknown) => events.push(event)
    } as never)
    const mapped = extension.mapSessionNotification?.({
      sessionId: "s1",
      update: {
        sessionUpdate: "tool_call",
        toolCallId: "sk",
        title: "skill",
        rawInput: { name: "tophat" }
      }
    } as never)
    expect(JSON.stringify(mapped)).toContain('"codevisorSkill":{"name":"tophat","ok":true}')
  })
})
