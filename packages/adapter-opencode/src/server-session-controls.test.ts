import { Effect } from "effect"
import { describe, expect, it, vi } from "vitest"

import type { Catalog } from "./catalog.js"
import {
  PATH,
  ROOT,
  catalog,
  delivered,
  isPrompt,
  run,
  setup,
  terminal
} from "./session-test-support.js"
import { event, firstQuestion, payload } from "./test-support.js"

describe("OpenCode server session controls", () => {
  it("approves permissions automatically unless a planning mode is selected", async () => {
    const s = setup()
    s.queue.push(
      event("permission.asked", { id: "per_1", sessionID: ROOT, action: "shell", resources: [] })
    )
    expect(
      (await s.requested((request) => request.path.endsWith("/permission/per_1/reply"))).body
    ).toEqual({ decision: "once" })

    const planning = setup({ info: { agent: "plan" } })
    planning.queue.push(
      event("session.tool.input.started", { sessionID: ROOT, id: "call_1", name: "shell" }),
      event("permission.asked", {
        id: "per_2",
        sessionID: ROOT,
        action: "shell",
        resources: ["echo hi"],
        source: { type: "tool", messageID: "msg_a", id: "call_1" }
      })
    )
    const asked = payload(
      await planning.emitted((entry) => payload(entry).sessionUpdate === "question")
    )
    expect(asked.questions).toEqual([
      {
        allowsOther: false,
        id: "permission",
        options: [{ label: "Allow once" }, { label: "Always allow" }, { label: "Reject" }],
        question: "Allow the agent to proceed?"
      }
    ])
    await run(
      planning.handle.answerQuestion!(String(asked.questionId), {
        outcome: "answered",
        answers: { permission: { answers: ["Always allow"] } }
      })
    )
    expect(
      (await planning.requested((request) => request.path.endsWith("/permission/per_2/reply"))).body
    ).toEqual({ decision: "always" })
    expect(planning.updates("question_resolved")).toEqual([
      expect.objectContaining({ outcome: "answered", questionId: asked.questionId })
    ])
  })

  it("withdraws a permission question another client answered and cancels forms it cannot show", async () => {
    const s = setup({ info: { agent: "plan" } })
    s.queue.push(
      event("permission.asked", {
        id: "per_1",
        sessionID: ROOT,
        action: "shell",
        resources: [],
        metadata: { command: "rm -rf build" }
      })
    )
    const asked = payload(await s.emitted((entry) => payload(entry).sessionUpdate === "question"))
    expect(firstQuestion(asked)).toBe("shell: rm -rf build")
    s.queue.push(
      event("permission.replied", { sessionID: ROOT, requestID: "per_1", reply: "reject" }),
      event("form.created", { form: { id: "frm_1", sessionID: ROOT, fields: [] } })
    )
    await s.requested(
      (request) => request.method === "DELETE" && request.path === `${PATH}/form/frm_1`
    )
    expect(s.updates("question_resolved")).toEqual([
      expect.objectContaining({ outcome: "cancelled", questionId: asked.questionId })
    ])
    expect(s.requests.some((request) => request.path.includes("/permission/"))).toBe(false)
  })

  it("switches models, effort and modes, reloading the catalog for models it has not seen", async () => {
    const fresh: Catalog = {
      ...catalog,
      models: [...catalog.models, { providerID: "xai", id: "grok", name: "Grok", variants: [] }]
    }
    const reloadCatalog = vi.fn(async () => fresh)
    const s = setup({ reloadCatalog })
    const options = await run(s.handle.setConfigOption("model", "openrouter/m1/high"))
    expect(options.find((option) => option.id === "effort")?.currentValue).toBe("high")
    expect(s.requests.at(-1)).toMatchObject({
      path: `${PATH}/model`,
      body: { model: { providerID: "openrouter", id: "m1", variant: "high" } }
    })
    await run(s.handle.setConfigOption("model", "xai/grok"))
    expect(reloadCatalog).toHaveBeenCalledOnce()
    await run(s.handle.setMode("plan"))
    expect(s.requests.at(-1)).toMatchObject({ path: `${PATH}/agent`, body: { agent: "plan" } })
    expect(
      s.events
        .map(payload)
        .filter((entry) => entry.configId !== undefined || entry.modeId !== undefined)
    ).toEqual([
      expect.objectContaining({ configId: "model", value: "openrouter/m1/high" }),
      expect.objectContaining({ configId: "model", value: "xai/grok" }),
      { modeId: "plan" }
    ])
    await expect(run(s.handle.setConfigOption("effort", "ludicrous"))).rejects.toThrow(
      "Unknown OpenCode effort: ludicrous"
    )
    await run(s.handle.setConfigOption("mode", "build"))
    expect(s.events.map(payload).at(-1)).toMatchObject({ configId: "mode", modeId: "build" })
  })

  it("follows model and mode switches made by other OpenCode clients", async () => {
    const s = setup()
    s.queue.push(
      event("session.agent.selected", { sessionID: ROOT, agent: "plan" }),
      event("session.model.selected", {
        sessionID: ROOT,
        model: { providerID: "opencode", id: "m2" }
      })
    )
    const update = payload(
      await s.emitted((entry) => payload(entry).sessionUpdate === "config_option_update")
    )
    expect(update.configOptions).toEqual([
      expect.objectContaining({ id: "model", currentValue: "opencode/m2" })
    ])
    expect(s.updates("config_option_update")).toHaveLength(1)
    expect(s.updates("current_mode_update")).toEqual([
      { sessionUpdate: "current_mode_update", currentModeId: "plan" }
    ])
  })

  it("closes by interrupting the running turn, ending the subscription and releasing the server", async () => {
    const s = setup()
    const turn = run(Effect.result(s.handle.prompt("go")))
    await s.requested(isPrompt("msg_1"))
    await run(s.handle.close)
    await run(s.handle.close)
    expect(await turn).toMatchObject({ failure: { message: "This OpenCode session was closed." } })
    expect(s.requests.at(-1)).toMatchObject({ path: `${PATH}/interrupt`, method: "POST" })
    expect(s.released()).toBe(1)
    expect(await run(Effect.result(s.handle.prompt("after")))).toMatchObject({
      failure: { message: "This OpenCode session is closed." }
    })
  })

  it("nests subagent output, with its file diffs, under the task call that started it", async () => {
    const s = setup()
    const turn = run(s.handle.prompt("delegate"))
    await s.requested(isPrompt("msg_1"))
    s.queue.push(
      delivered("msg_1"),
      event("session.tool.input.started", { sessionID: ROOT, id: "call_task", name: "subagent" }),
      event("session.tool.called", {
        sessionID: ROOT,
        id: "call_task",
        input: { description: "Fix file", agent: "general", prompt: "fix it" }
      }),
      event("session.created", { sessionID: "ses_child", parentID: ROOT, title: "Fix file" }),
      event("session.tool.input.started", {
        sessionID: "ses_child",
        id: "call_edit",
        name: "edit"
      }),
      event("session.tool.success", {
        sessionID: "ses_child",
        id: "call_edit",
        content: [],
        metadata: {
          files: [
            {
              file: "a.txt",
              status: "modified",
              patch: "--- a\n+++ a\n@@ -1,1 +1,1 @@\n-before\n+after\n"
            }
          ]
        }
      }),
      terminal("succeeded")
    )
    await turn
    const task = s.updates("tool_call_update").find((update) => update.toolCallId === "call_task")
    expect(task).toMatchObject({
      kind: "agent",
      title: "Fix file",
      rawInput: { subagent_type: "general" }
    })
    const nested = s.events.map(payload).filter((entry) => entry.parentToolCallId === "call_task")
    expect(nested.at(-1)).toMatchObject({
      toolCallId: "ses_child:call_edit",
      status: "completed",
      diffStats: [{ path: "/work/a.txt", added: 1, removed: 1 }]
    })
  })

  it("refreshes the account before each turn and interrupts lingering work when idle", async () => {
    const order: Array<string> = []
    const s = setup({
      beforeTurn: async () => {
        order.push("refresh")
      },
      respond: (request) => {
        order.push(request.path)
        return undefined
      }
    })
    const turn = run(s.handle.prompt("go"))
    await s.requested(isPrompt("msg_1"))
    expect(order).toEqual(["refresh", `${PATH}/prompt`])
    s.queue.push(delivered("msg_1"), terminal("succeeded"))
    await turn
    await run(s.handle.cancel)
    expect(order.at(-1)).toBe(`${PATH}/interrupt`)
  })

  it("rejects pending permission questions when the turn is cancelled", async () => {
    const s = setup({ info: { agent: "plan" } })
    s.queue.push(
      event("permission.asked", {
        id: "per_1",
        sessionID: ROOT,
        action: "webfetch",
        metadata: { url: "https://x.dev" }
      })
    )
    const asked = payload(await s.emitted((entry) => payload(entry).sessionUpdate === "question"))
    expect(firstQuestion(asked)).toBe("webfetch: https://x.dev")
    await run(s.handle.cancel)
    expect(
      (await s.requested((request) => request.path.endsWith("/permission/per_1/reply"))).body
    ).toEqual({
      decision: "reject"
    })
    expect(s.updates("question_resolved")).toEqual([
      expect.objectContaining({ outcome: "cancelled" })
    ])
    await expect(
      run(s.handle.answerQuestion!(String(asked.questionId), { outcome: "cancelled" }))
    ).rejects.toThrow("No pending question")
  })
})
