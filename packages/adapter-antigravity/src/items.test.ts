import { describe, expect, it } from "vitest"

import { agyToolKind, agyToolTitle, makeAgyStepMapper } from "./items.js"
import type { AgyStep } from "./protocol.js"

const C = "c-1"

const step = (fields: Partial<AgyStep> & Record<string, unknown>): AgyStep => ({
  conversation_id: C,
  step_index: 3,
  state: "DONE",
  step_type: "tool",
  ...fields
})

const tool = (
  name: string,
  parameters: Record<string, unknown>,
  fields: Record<string, unknown> = {}
) => step({ tool_name: name, tool_info: { name, parameters, ...fields } })

const payloads = (events: ReadonlyArray<{ payload: Record<string, unknown> }>) =>
  events.map((event) => event.payload)

describe("agy step mapping", () => {
  it("opens a tool row as agy starts it and settles it with its output", () => {
    const mapper = makeAgyStepMapper(() => C)
    const command = { CommandLine: "bun test", Cwd: "/repo" }
    expect(
      payloads(
        mapper.step(
          step({
            state: "ACTIVE",
            tool_name: "run_command",
            tool_info: { name: "run_command", parameters: command }
          })
        )
      )
    ).toEqual([
      {
        sessionUpdate: "tool_call",
        status: "in_progress",
        toolCallId: `${C}:3`,
        kind: "execute",
        title: "bun test",
        rawInput: command
      }
    ])
    expect(payloads(mapper.step(tool("run_command", command, { output: "3 passed\r\n" })))).toEqual(
      [
        {
          sessionUpdate: "tool_call_update",
          toolCallId: `${C}:3`,
          kind: "execute",
          title: "bun test",
          rawInput: command,
          status: "completed",
          content: [{ type: "content", content: { type: "text", text: "3 passed\r\n" } }],
          rawOutput: "3 passed\r\n"
        }
      ]
    )
    // A settled step agy sends again changes nothing.
    expect(mapper.step(tool("run_command", command, { output: "3 passed\r\n" }))).toEqual([])
  })

  it("opens and settles a tool first seen already done", () => {
    const mapper = makeAgyStepMapper(() => C)
    const events = payloads(
      mapper.step(tool("view_file", { AbsolutePath: "/repo/a.ts" }, { output: "x" }))
    )
    expect(events.map((event) => [event.sessionUpdate, event.status])).toEqual([
      ["tool_call", "in_progress"],
      ["tool_call_update", "completed"]
    ])
    expect(events[0]).toMatchObject({
      kind: "read",
      title: "/repo/a.ts",
      locations: [{ path: "/repo/a.ts" }]
    })
  })

  it("rebuilds a written file's diff from the content agy wrote", () => {
    const [, settled] = payloads(
      makeAgyStepMapper(() => C).step(
        tool("write_to_file", { TargetFile: "/repo/new.ts", CodeContent: "a\nb\n" })
      )
    )
    expect(settled).toMatchObject({
      kind: "edit",
      title: "/repo/new.ts",
      content: [{ type: "diff", path: "/repo/new.ts", oldText: null, newText: "a\nb\n" }],
      diffStats: [{ path: "/repo/new.ts", added: 2, removed: 0 }]
    })
  })

  it("rebuilds a replacement's diff from one inline chunk or a list of them", () => {
    const mapper = makeAgyStepMapper(() => C)
    const [, single] = payloads(
      mapper.step(
        tool("replace_file_content", {
          TargetFile: "/repo/a.ts",
          TargetContent: "old\n",
          ReplacementContent: "new\n"
        })
      )
    )
    expect(single).toMatchObject({
      content: [{ type: "diff", path: "/repo/a.ts", oldText: "old\n", newText: "new\n" }],
      diffStats: [{ path: "/repo/a.ts", added: 1, removed: 1 }]
    })
    const [, multi] = payloads(
      mapper.step(
        step({
          step_index: 4,
          tool_name: "multi_replace_file_content",
          tool_info: {
            name: "multi_replace_file_content",
            parameters: {
              TargetFile: "/repo/b.ts",
              ReplacementChunks: [
                { TargetContent: "a\n", ReplacementContent: "a\nb\n" },
                { ReplacementContent: "c\n" },
                { TargetContent: "skipped" }
              ]
            }
          }
        })
      )
    )
    expect(multi).toMatchObject({
      content: [
        { type: "diff", path: "/repo/b.ts", oldText: "a\n", newText: "a\nb\n" },
        { type: "diff", path: "/repo/b.ts", oldText: null, newText: "c\n" }
      ],
      diffStats: [{ path: "/repo/b.ts", added: 2, removed: 0 }]
    })
  })

  it("shows no diff for an edit it can't rebuild, or one that failed", () => {
    const mapper = makeAgyStepMapper(() => C)
    const [, unreadable] = payloads(
      mapper.step(
        tool("replace_file_content", { TargetFile: "/repo/a.ts", ReplacementChunks: [{}] })
      )
    )
    expect(unreadable).not.toHaveProperty("diffStats")
    const [, failed] = payloads(
      mapper.step(
        step({
          step_index: 9,
          state: "ERROR",
          tool_name: "write_to_file",
          tool_info: {
            name: "write_to_file",
            parameters: { TargetFile: "/repo/a.ts", CodeContent: "x" },
            error: { type: "TOOL_ERROR", message: "permission denied" }
          }
        })
      )
    )
    expect(failed).toMatchObject({
      status: "failed",
      content: [{ type: "content", content: { type: "text", text: "permission denied" } }]
    })
    expect(failed).not.toHaveProperty("diffStats")
    const [, unexplained] = payloads(
      mapper.step(
        step({
          step_index: 10,
          state: "ERROR",
          tool_info: { name: "run_command", parameters: {}, output: "exit status 1" }
        })
      )
    )
    expect(unexplained).toMatchObject({
      status: "failed",
      content: [{ type: "content", content: { type: "text", text: "exit status 1" } }]
    })
  })

  it("shows a subagent as an agent row named for its task", () => {
    const mapper = makeAgyStepMapper(() => C)
    const long =
      "Review every file under src/server for unchecked errors and report the worst offenders first"
    const [opened] = payloads(
      mapper.step(
        tool(
          "invoke_subagent",
          { Subagents: [{ Prompt: long }, { Prompt: "Second task" }] },
          {
            output: "done"
          }
        )
      )
    )
    expect(opened).toMatchObject({
      kind: "agent",
      title: "Agent: Review every file under src/server for unchecked errors and… (+1 more)",
      rawInput: { prompt: `${long}\n\nSecond task` },
      _meta: { codevisorSubagent: { taskId: `${C}:3` } }
    })
    const [unnamed] = payloads(
      makeAgyStepMapper(() => C).step(tool("invoke_subagent", { Subagents: [{}] }))
    )
    expect(unnamed).toMatchObject({ title: "Agent", rawInput: {} })
    const [short] = payloads(
      makeAgyStepMapper(() => C).step(tool("invoke_subagent", { Prompt: "Fix the build" }))
    )
    expect(short).toMatchObject({ title: "Agent: Fix the build" })
    const [unbroken] = payloads(
      makeAgyStepMapper(() => C).step(tool("invoke_subagent", { Prompt: "x".repeat(80) }))
    )
    expect(unbroken).toMatchObject({ title: `Agent: ${"x".repeat(60)}…` })
  })

  it("reports usage from any step and leaves a subagent's own steps to its row", () => {
    const mapper = makeAgyStepMapper(() => C)
    expect(mapper.step(step({ step_type: "checkpoint", usage: { total_tokens: 123 } }))).toEqual([
      { kind: "session.updated", payload: { sessionUpdate: "usage_update", used: 123 } }
    ])
    expect(mapper.step(step({ step_type: "checkpoint", usage: { total_tokens: 0 } }))).toEqual([])
    expect(
      mapper.step(step({ conversation_id: "child", step_type: "agent_response", text_delta: "hi" }))
    ).toEqual([])
    expect(mapper.step(step({ step_type: "agent_response", text_delta: "" }))).toEqual([])
  })

  it("keys steps by the chat's conversation before agy names it", () => {
    const [chunk] = payloads(
      makeAgyStepMapper(() => "").step({
        step_index: 0,
        state: "ACTIVE",
        step_type: "agent_response",
        text_delta: "hi"
      })
    )
    expect(chunk).toMatchObject({ messageId: ":0" })
    const [row] = payloads(
      makeAgyStepMapper(() => "").step({ step_index: 1, state: "ACTIVE", step_type: "tool_call" })
    )
    expect(row).toMatchObject({ kind: "other", title: "tool", rawInput: {} })
  })

  it("titles MCP calls by server and tool, and leaves out agy's schema reads", () => {
    const mapper = makeAgyStepMapper(() => C)
    const [opened] = payloads(
      mapper.step(
        tool(
          "call_mcp_tool",
          { ServerName: "codevisor", ToolName: "skills", Arguments: { name: "deploy" } },
          { output: "…" }
        )
      )
    )
    expect(opened).toMatchObject({
      kind: "other",
      title: "codevisor.skills",
      rawInput: { name: "deploy" }
    })
    const [unnamed] = payloads(
      makeAgyStepMapper(() => C).step(tool("call_mcp_tool", { toolSummary: "Calling a tool" }))
    )
    expect(unnamed).toMatchObject({ title: "Calling a tool" })
    expect(
      mapper.step(
        step({
          step_index: 4,
          tool_name: "view_file",
          tool_info: {
            name: "view_file",
            parameters: { AbsolutePath: "/p/gemini/antigravity-cli/mcp/codevisor/skills.json" }
          }
        })
      )
    ).toEqual([])
  })

  it("names agy's tools by kind and what they act on", () => {
    expect(
      [
        "view_file_outline",
        "view_code_item",
        "list_dir",
        "send_command_input",
        "command_status",
        "grep_search",
        "find_by_name",
        "codebase_search",
        "read_url_content",
        "search_web",
        "ask_question"
      ].map(agyToolKind)
    ).toEqual([
      "read",
      "read",
      "read",
      "execute",
      "execute",
      "search",
      "search",
      "search",
      "fetch",
      "fetch",
      "other"
    ])
    expect(agyToolTitle("grep_search", { query: "TODO" })).toBe("TODO")
    expect(agyToolTitle("read_url_content", { Url: "https://x.dev" })).toBe("https://x.dev")
    expect(agyToolTitle("manage_task", { toolSummary: "Update the plan" })).toBe("Update the plan")
    expect(agyToolTitle("manage_task", {})).toBe("manage_task")
  })
})
