import { describe, expect, it } from "vitest"

import { makeMuseItemMapper } from "./items.js"
import type { MuseItem } from "./protocol.js"

const payloads = (events: ReadonlyArray<{ payload: Record<string, unknown> }>) =>
  events.map((entry) => entry.payload)

describe("Muse subagent rows", () => {
  it("shows subagents as agent rows with their objective and result", () => {
    const mapper = makeMuseItemMapper()
    const agent = {
      itemId: "a1",
      kind: "subagent",
      revision: 1,
      status: "inProgress",
      objective: "Find the bug\nin parser",
      role: "explorer"
    }
    expect(payloads(mapper.item(agent, "started"))).toEqual([
      {
        sessionUpdate: "tool_call",
        toolCallId: "a1",
        kind: "agent",
        status: "in_progress",
        // No agent path: the objective's first line names it.
        title: "Agent: Find the bug",
        rawInput: { prompt: "Find the bug\nin parser" }
      }
    ])
    expect(mapper.item({ ...agent, revision: 2 }, "updated")).toEqual([])
    expect(
      payloads(
        mapper.item(
          {
            ...agent,
            revision: 3,
            status: "completed",
            result: { summary: "Found it" }
          },
          "completed"
        )
      )
    ).toEqual([
      {
        sessionUpdate: "tool_call_update",
        toolCallId: "a1",
        status: "completed",
        content: [{ type: "content", content: { type: "text", text: "Found it" } }]
      }
    ])
    const bare = payloads(
      mapper.item(
        {
          itemId: "a2",
          kind: "subagent",
          revision: 2,
          status: "failed",
          failureReason: "stopped"
        },
        "completed"
      )
    )
    expect(bare[0]).toMatchObject({ title: "Agent" })
    expect(bare[0]).not.toHaveProperty("rawInput")
    expect(bare[1]).toMatchObject({
      status: "failed",
      content: [{ type: "content", content: { type: "text", text: "stopped" } }]
    })
  })

  it("names a subagent by the task Muse gave it, not its whole objective", () => {
    const title = (fields: Partial<MuseItem>) =>
      payloads(
        makeMuseItemMapper().item(
          {
            itemId: "a",
            kind: "subagent",
            revision: 1,
            status: "inProgress",
            ...fields
          },
          "started"
        )
      )[0]!.title
    // As Muse 1.4.7 reports it: the objective is the full instruction.
    const objective =
      "Review /private/tmp/ws/calc.py and /private/tmp/ws/main.py for bugs. Read both files in full, inspect for correctness, and report each bug."
    expect(
      title({
        agentPath: "main/Review calc.py and main.py/1",
        objective,
        role: "Code reviewer"
      })
    ).toBe("Agent: Review calc.py and main.py")
    // A nested subagent's path extends its parent's; its own name is last.
    expect(title({ agentPath: "main/Audit repo/1/Check tests/2" })).toBe("Agent: Check tests")
    // Without a usable path, the objective is cut at a word, then the role.
    expect(title({ agentPath: "main/1", objective })).toBe(
      "Agent: Review /private/tmp/ws/calc.py and /private/tmp/ws/main.py…"
    )
    expect(title({ objective: "x".repeat(80) })).toBe(`Agent: ${"x".repeat(60)}…`)
    expect(title({ objective: "  ", role: "Code reviewer" })).toBe("Agent (Code reviewer)")
  })

  it("marks a subagent answered once Muse holds its result, and reopens it for follow-up work", () => {
    const mapper = makeMuseItemMapper()
    const agent = {
      itemId: "a9",
      kind: "subagent",
      status: "inProgress",
      childSessionId: "c"
    }
    mapper.item({ ...agent, revision: 1, controlStatus: "accepted" }, "started")
    expect(mapper.item({ ...agent, revision: 2, controlStatus: "running" }, "updated")).toEqual([])
    // As Muse 1.4.7 reports it: the item stays open, its control status says it answered.
    const ready = {
      ...agent,
      revision: 3,
      controlStatus: "resultReady",
      result: { summary: "s", text: "No bugs." }
    }
    expect(payloads(mapper.item(ready, "updated"))).toEqual([
      {
        sessionUpdate: "tool_call_update",
        toolCallId: "a9",
        status: "completed",
        content: [{ type: "content", content: { type: "text", text: "No bugs." } }]
      }
    ])
    expect(mapper.item({ ...ready, revision: 4 }, "updated")).toEqual([])
    expect(
      payloads(mapper.item({ ...agent, revision: 5, controlStatus: "running" }, "updated"))
    ).toEqual([
      {
        sessionUpdate: "tool_call_update",
        toolCallId: "a9",
        status: "in_progress"
      }
    ])
    expect(
      payloads(mapper.item({ ...agent, revision: 6, controlStatus: "closed" }, "updated"))[0]
    ).toMatchObject({
      status: "completed"
    })
  })
})

// The parent messaging a subagent.
const send = (itemId: string, turnId: string, args: Record<string, unknown>) => ({
  itemId,
  kind: "toolCall",
  tool: "subagent_send_message",
  turnId,
  args: JSON.stringify({
    command_id: itemId,
    message: "Add an edge case",
    ...args
  })
})

describe("Muse subagent follow-ups", () => {
  // Turn 1 spawns Checker and it answers; frames as Muse 1.4.7 reports them.
  const T1 = "turn-1",
    T2 = "turn-2"
  const checker = {
    itemId: "a1",
    kind: "subagent",
    status: "inProgress",
    childSessionId: "c1",
    subagentId: "subagent-1",
    agentPath: "main/Checker/1",
    turnId: T1
  }
  const spawned = () => {
    const mapper = makeMuseItemMapper(() => "chat")
    mapper.item({ ...checker, revision: 1, controlStatus: "accepted" }, "started")
    mapper.item({ ...checker, revision: 2, controlStatus: "resultReady" }, "updated")
    return mapper
  }
  const delivered = (call: MuseItem, visibleOutput: string) =>
    payloads(
      spawned().item({ ...call, revision: 2, status: "completed", visibleOutput }, "completed")
    )
  const taskId = { taskId: "chat:subagent-1" }

  it("reopens the agent's row for a message sent in the same turn", () => {
    const mapper = spawned()
    expect(
      payloads(
        mapper.item(
          {
            ...send("m1", T1, { subagent_id: "subagent-1" }),
            revision: 1,
            status: "inProgress"
          },
          "started"
        )
      )
    ).toEqual([
      {
        sessionUpdate: "tool_call",
        toolCallId: "m1",
        kind: "other",
        status: "in_progress",
        title: "Messaged agent: Checker",
        rawInput: { message: "Add an edge case" },
        _meta: { codevisorSubagent: taskId }
      }
    ])
    expect(
      payloads(mapper.item({ ...checker, revision: 3, controlStatus: "running" }, "updated"))
    ).toEqual([
      {
        sessionUpdate: "tool_call_update",
        toolCallId: "a1",
        status: "in_progress"
      }
    ])
    expect(mapper.runRow("a1")).toBe("a1")
    // A subagent the chat never saw start streams under its own item.
    expect(mapper.runRow("elsewhere")).toBe("elsewhere")
  })

  it("gives a later turn's run its own chip, which the agent's work and result go to", () => {
    const mapper = spawned()
    // Muse rejects a message sent by id once the spawning turn ended…
    const byId = send("m1", T2, { subagent_id: "subagent-1" })
    mapper.item({ ...byId, revision: 1, status: "inProgress" }, "started")
    expect(
      payloads(
        mapper.item(
          {
            ...byId,
            revision: 2,
            status: "completed",
            visibleOutput: '{"status":"rejected","reason":"terminal","subagent_id":"subagent-1"}'
          },
          "completed"
        )
      )
    ).toEqual([
      {
        sessionUpdate: "tool_call_update",
        toolCallId: "m1",
        status: "failed",
        content: [
          {
            type: "content",
            content: { type: "text", text: "Not delivered (terminal)" }
          }
        ]
      }
    ])
    // …and takes one sent by the agent's path.
    const byPath = send("m2", T2, {
      agent_path: "main/Checker/1",
      mode: "followup"
    })
    expect(
      payloads(mapper.item({ ...byPath, revision: 1, status: "inProgress" }, "started"))[0]
    ).toMatchObject({ toolCallId: "m2", title: "Messaged agent: Checker" })
    expect(
      payloads(mapper.item({ ...checker, revision: 3, controlStatus: "running" }, "updated"))
    ).toEqual([
      {
        sessionUpdate: "tool_call",
        toolCallId: "a1:2",
        kind: "agent",
        status: "in_progress",
        title: "Agent: Checker",
        rawInput: {},
        _meta: { codevisorSubagent: { ...taskId, continues: true } }
      }
    ])
    expect(mapper.runRow("a1")).toBe("a1:2")
    expect(
      payloads(
        mapper.item(
          {
            ...byPath,
            revision: 2,
            status: "completed",
            visibleOutput: '{"status":"accepted"}'
          },
          "completed"
        )
      )
    ).toEqual([
      {
        sessionUpdate: "tool_call_update",
        toolCallId: "m2",
        status: "completed"
      }
    ])
    expect(mapper.item({ ...checker, revision: 4, controlStatus: "running" }, "updated")).toEqual(
      []
    )
    expect(
      payloads(
        mapper.item(
          {
            ...checker,
            revision: 5,
            controlStatus: "resultReady",
            result: { text: "add(-5, 5) == 0" }
          },
          "updated"
        )
      )
    ).toEqual([
      {
        sessionUpdate: "tool_call_update",
        toolCallId: "a1:2",
        status: "completed",
        content: [
          {
            type: "content",
            content: { type: "text", text: "add(-5, 5) == 0" }
          }
        ]
      }
    ])
  })

  it("finds the agent a message names by its task alone, and drops one for no agent it knows", () => {
    const mapper = spawned()
    expect(
      payloads(
        mapper.item(
          {
            ...send("m1", T2, { agent_path: "Checker", task: "Again" }),
            revision: 1,
            status: "inProgress",
            args: '{"agent_path":"main/Checker","task":"Again"}'
          },
          "started"
        )
      )[0]
    ).toMatchObject({
      title: "Messaged agent: Checker",
      rawInput: { message: "Again" }
    })
    expect(
      mapper.item(
        {
          ...send("m2", T2, { subagent_id: "subagent-9" }),
          revision: 1,
          status: "inProgress"
        },
        "started"
      )
    ).toEqual([])
    expect(
      mapper.item(
        {
          ...send("m3", T2, {}),
          revision: 1,
          status: "inProgress",
          args: "{}"
        },
        "started"
      )
    ).toEqual([])
    // A rejection with no reason, and a call that failed outright.
    expect(
      delivered(
        {
          ...send("m4", T1, { subagent_id: "subagent-1" }),
          revision: 1,
          status: "inProgress"
        },
        '{"status":"rejected"}'
      )
    ).toEqual([
      expect.objectContaining({ sessionUpdate: "tool_call" }),
      {
        sessionUpdate: "tool_call_update",
        toolCallId: "m4",
        status: "failed",
        content: [{ type: "content", content: { type: "text", text: "Not delivered" } }]
      }
    ])
    // An agent with no task or objective goes by its role, else "agent".
    const unnamed = makeMuseItemMapper()
    for (const [subagentId, role] of [
      ["subagent-2", "tester"],
      ["subagent-3", undefined]
    ] as const)
      unnamed.item(
        {
          itemId: subagentId,
          kind: "subagent",
          revision: 1,
          status: "inProgress",
          subagentId,
          ...(role ? { role } : {})
        },
        "started"
      )
    const titles = ["subagent-2", "subagent-3"].map(
      (subagent_id) =>
        payloads(
          unnamed.item(
            {
              ...send(`to-${subagent_id}`, T1, {
                subagent_id,
                message: undefined
              }),
              revision: 1,
              status: "inProgress"
            },
            "started"
          )
        )[0]
    )
    expect(titles).toEqual([
      expect.objectContaining({
        title: "Messaged agent: tester",
        rawInput: { message: "" },
        _meta: { codevisorSubagent: { taskId: ":subagent-2" } }
      }),
      expect.objectContaining({ title: "Messaged agent: agent" })
    ])
    const failed = spawned()
    const call = send("m5", T1, {
      subagent_id: "subagent-1",
      message: undefined,
      objective: "Retry"
    })
    expect(
      payloads(failed.item({ ...call, revision: 1, status: "inProgress" }, "started"))[0]
    ).toMatchObject({ rawInput: { message: "Retry" } })
    expect(failed.item({ ...call, revision: 2, status: "inProgress" }, "updated")).toEqual([])
    expect(payloads(failed.item({ ...call, revision: 3, status: "failed" }, "completed"))).toEqual([
      { sessionUpdate: "tool_call_update", toolCallId: "m5", status: "failed" }
    ])
  })
})
