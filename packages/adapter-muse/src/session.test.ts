import { describe, expect, it } from "vitest"

import { MuseRequestError } from "./client.js"
import {
  FakeMuseClient,
  payloads,
  send,
  SESSION,
  session,
  startChat as start,
  turns
} from "./test-support.js"

describe("Muse chat", () => {
  it("starts a full-access session carrying Codevisor's tool gateway", async () => {
    const client = new FakeMuseClient()
    client.replies["skill/list"] = { skills: [{ selector: "plan", displayName: "plan" }] }
    const { chat } = await start(
      { toolGateway: { name: "codevisor", url: "http://127.0.0.1:7/mcp", bearerToken: "t" } },
      client
    )
    expect(client.sent("session/start")[0]).toEqual({
      commandId: expect.stringMatching(/^[0-9a-f]{8}-[0-9a-f]{4}-7/),
      workspaceRoot: "/repo",
      approvalMode: "allowAll",
      config: {
        mcpServers: {
          codevisor: {
            transport: "streamableHttp",
            url: "http://127.0.0.1:7/mcp",
            headers: { Authorization: "Bearer t" },
            mode: "optional"
          }
        }
      }
    })
    expect(chat.key).toBe(SESSION)
    expect(chat.configOptions().map((option) => option.currentValue)).toEqual(["spark", "medium"])
    expect(chat.skills?.skills.map((skill) => skill.invocation)).toEqual(["/plan"])
  })

  it("resumes, dropping a gateway the session already has a different credential for", async () => {
    const client = new FakeMuseClient()
    let attempts = 0
    client.replies["session/resume"] = (params: Record<string, unknown>) => {
      attempts += 1
      return "config" in params
        ? Promise.reject(
            new MuseRequestError(
              "session_configuration_conflict: mcpServers",
              -32030,
              "commandRejected"
            )
          )
        : { session: session({ modelId: null }) }
    }
    client.replies["model/list"] = new Error("catalog unavailable")
    client.replies["skill/list"] = new Error("no skills")
    const { chat } = await start(
      { resume: SESSION, toolGateway: { name: "g", url: "u", bearerToken: "b" } },
      client
    )
    expect(attempts).toBe(2)
    // A resumed session runs with full access like a new one.
    expect(client.sent("session/setApprovalMode")).toEqual([
      { commandId: expect.any(String), sessionId: SESSION, mode: "allowAll" }
    ])
    expect(client.sent("session/resume")[1]).toEqual({
      commandId: expect.any(String),
      sessionId: SESSION,
      excludeItems: true
    })
    expect(chat.configOptions()).toEqual([])
    expect(chat.skills).toBeUndefined()
    // Without skills a leading slash is plain text.
    await send(chat, client, "/plan")
    expect(client.sent("turn/start")[0]!.input).toEqual([{ type: "text", text: "/plan" }])
    // A session that names no model runs Muse's active one.
    const unnamed = new FakeMuseClient()
    unnamed.replies["session/start"] = { session: session({ modelId: null }) }
    expect((await start({}, unnamed)).chat.configOptions()[0]!.currentValue).toBe("spark")
    const odd = new FakeMuseClient()
    odd.replies["model/list"] = { models: "none" }
    expect((await start({}, odd)).chat.configOptions()).toEqual([])

    // A host that can't switch modes still resumes.
    const fixed = new FakeMuseClient()
    fixed.replies["session/setApprovalMode"] = new Error("commandRejected")
    expect((await start({ resume: SESSION }, fixed)).chat.key).toBe(SESSION)

    const failing = new FakeMuseClient()
    failing.replies["session/resume"] = new MuseRequestError(
      "session not found",
      -32011,
      "notFound"
    )
    await expect(start({ resume: "gone" }, failing)).rejects.toThrow("session not found")
    failing.replies["session/resume"] = new Error("pipe closed")
    await expect(
      start({ resume: "gone", toolGateway: { name: "g", url: "u", bearerToken: "b" } }, failing)
    ).rejects.toThrow("pipe closed")
  })

  it("runs a prompt from turn/start to turn/completed", async () => {
    const { client, chat, events } = await start()
    const { finished } = await send(chat, client, "Fix the bug")
    const [sent] = client.sent("turn/start")
    expect(sent).toEqual({
      commandId: expect.any(String),
      sessionId: SESSION,
      input: [{ type: "text", text: "Fix the bug" }]
    })
    const turnId = sent!.commandId
    client.emit("turn/started", { turnId })
    client.emit("item/delta", { itemId: "m1", field: "text", delta: "Fixed." })
    client.emit("item/delta", { itemId: "m1", delta: "!" })
    client.emit("turn/completed", { turnId: "someone-else", terminal: "completed" })
    client.emit("turn/completed", { turnId, terminal: "completed" })
    await expect(finished).resolves.toEqual({ stopReason: "end_turn" })
    expect(
      payloads(events).filter((payload) => payload.sessionUpdate === "agent_message_chunk")
    ).toHaveLength(2)
    expect(turns(events)).toEqual([
      { initiatedBy: "user", turnId: expect.any(String), turnState: "started" },
      {
        initiatedBy: "user",
        stopReason: "end_turn",
        turnId: expect.any(String),
        turnState: "ended"
      }
    ])
  })

  it("explains failed turns, and offers a retry when Muse says it may work", async () => {
    const { client, chat, events } = await start()
    const run = async (completed: Record<string, unknown>) => {
      const { finished, turnId } = await send(chat, client)
      client.emit("turn/completed", { turnId, ...completed })
      await finished
      return turns(events).at(-1)
    }
    expect(
      await run({
        terminal: "failed",
        error: { kind: "authRequired", message: "no credential", retryable: false }
      })
    ).toMatchObject({
      stopReason: "end_turn",
      stopDetail: "Sign in to Muse Code to continue."
    })
    expect(
      await run({
        terminal: "failed",
        error: { kind: "provider", message: "Overloaded", retryable: true }
      })
    ).toMatchObject({
      stopDetail: "Overloaded",
      retryable: true
    })
    expect(await run({ terminal: "failed", reason: "host died" })).toMatchObject({
      stopDetail: "host died"
    })
    expect(await run({ terminal: "failed" })).toMatchObject({
      stopDetail: "Muse stopped with an error."
    })
    expect(await run({ terminal: "cancelled" })).toMatchObject({ stopReason: "cancelled" })
  })

  it("ends a turn Muse rejects, reclaims, or never started", async () => {
    const { client, chat, events } = await start()
    client.replies["turn/start"] = new MuseRequestError("not signed in", -32010, "authRequired")
    await chat.prompt("go")
    expect(turns(events).at(-1)).toMatchObject({ stopDetail: "Sign in to Muse Code to continue." })
    client.replies["turn/start"] = new Error("busy")
    await chat.prompt("go")
    expect(turns(events).at(-1)).toMatchObject({ stopDetail: "busy" })
    // A queued turn reclaimed before launch ends without turn/completed.
    client.replies["turn/start"] = { status: "accepted" }
    const queued = await send(chat, client, "later")
    client.emit("turn/unqueued", { turnId: queued.turnId })
    await expect(queued.finished).resolves.toEqual({ stopReason: "end_turn" })
    // Muse can start a turn of its own (a background task settling).
    client.emit("turn/completed", { turnId: "x", terminal: "completed" })
    client.emit("turn/started", { turnId: "bg-1" })
    client.emit("turn/started", { turnId: "bg-2" })
    client.emit("turn/completed", { turnId: "bg-1", terminal: "completed" })
    expect(turns(events).slice(-2)).toEqual([
      { initiatedBy: "agent", turnId: expect.any(String), turnState: "started" },
      {
        initiatedBy: "agent",
        stopReason: "end_turn",
        turnId: expect.any(String),
        turnState: "ended"
      }
    ])
  })

  it("interrupts the running turn and reports it cancelled", async () => {
    const { client, chat, events } = await start()
    await chat.cancel()
    expect(client.sent("turn/interrupt")).toEqual([])
    const { finished, turnId } = await send(chat, client, "long task")
    await chat.cancel()
    expect(client.sent("turn/interrupt")).toEqual([
      { commandId: expect.any(String), sessionId: SESSION, turnId }
    ])
    client.emit("turn/completed", { turnId, terminal: "completed" })
    await expect(finished).resolves.toEqual({ stopReason: "cancelled" })
    // An agent turn whose id Muse never sent is interrupted as "the current turn".
    client.emit("turn/started", {})
    await chat.cancel()
    expect(client.sent("turn/interrupt").at(-1)).toEqual({
      commandId: expect.any(String),
      sessionId: SESSION
    })
    expect(turns(events)).toHaveLength(3)
  })

  it("switches model and reasoning tier through Muse", async () => {
    const { client, chat } = await start()
    expect(await chat.setConfigOption("thought_level", "high")).toEqual([
      expect.objectContaining({ currentValue: "spark" }),
      expect.objectContaining({ currentValue: "high" })
    ])
    expect(client.sent("session/setReasoningEffort")[0]).toMatchObject({
      sessionId: SESSION,
      reasoningEffort: "high"
    })
    // Lite has no "high": its default takes over.
    const options = await chat.setConfigOption("model", "lite")
    expect(client.sent("session/setModel")[0]).toMatchObject({
      model: { modelId: "lite", providerId: "meta", profileId: null }
    })
    expect(options.map((option) => option.currentValue)).toEqual(["lite", "minimal"])
    await chat.setConfigOption("thought_level", "low")
    await chat.setConfigOption("model", "lite")
    expect(chat.configOptions()[1]!.currentValue).toBe("low")
    await expect(chat.setConfigOption("model", "gpt")).rejects.toThrow("Unknown model: gpt")
    await expect(chat.setConfigOption("thought_level", "ultra")).rejects.toThrow(
      "Unknown reasoning level: ultra"
    )
    await expect(chat.setConfigOption("mode", "plan")).rejects.toThrow(
      "Muse Code has no setting named mode"
    )
  })

  it("follows changes Muse announces: model, tier, name, usage, todos, skills", async () => {
    const { client, events } = await start()
    const at = events.length
    client.emit("session/reasoningEffortChanged", { reasoningEffort: "high" })
    client.emit("session/modelChanged", { modelId: "lite" })
    client.emit("session/reasoningEffortChanged", { reasoningEffort: "low" })
    client.emit("session/modelChanged", { modelId: "lite" })
    client.emit("session/modelChanged", {})
    client.emit("session/reasoningEffortChanged", {})
    client.emit("session/nameChanged", { name: "Parser fix" })
    client.emit("session/nameChanged", {})
    client.emit("session/tokenUsage", { cumulative: { totalTokens: 5 } })
    client.emit("session/contextUsage", { usedTokens: 9 })
    client.emit("session/todoListChanged", { items: [{ text: "a", status: "pending" }] })
    client.emit("model/listChanged", {})
    // Another session's events (a subagent's) are not this chat's.
    client.emit("session/nameChanged", { sessionId: "child", name: "Child" })
    const options = payloads(events.slice(at)).filter((payload) => "configOptions" in payload)
    expect(
      options.map((payload) =>
        (payload.configOptions as Array<{ currentValue: string }>).map(
          (option) => option.currentValue
        )
      )
    ).toEqual([
      ["spark", "high"],
      ["lite", "minimal"],
      ["lite", "low"],
      ["lite", "low"]
    ])
    expect(payloads(events.slice(at)).filter((payload) => !("configOptions" in payload))).toEqual([
      { sessionUpdate: "session_info_update", title: "Parser fix" },
      { sessionUpdate: "usage_update", totalTokens: 5 },
      { sessionUpdate: "usage_update", used: 9 },
      { sessionUpdate: "plan", entries: [{ content: "a", priority: "medium", status: "pending" }] }
    ])

    // A listing that fails publishes nothing; the next good one does.
    const skillUpdates = () =>
      payloads(events).filter((payload) => payload.sessionUpdate === "available_skills_update")
    client.replies["skill/list"] = new Error("gone")
    client.emit("skill/changed")
    client.replies["skill/list"] = { skills: [{ selector: "new" }] }
    const published = new Promise<void>((resolve) => {
      const push = events.push.bind(events)
      events.push = (...added) => {
        const length = push(...added)
        if (
          added.some(
            (event) =>
              (event.payload as Record<string, unknown>).sessionUpdate === "available_skills_update"
          )
        )
          resolve()
        return length
      }
    })
    client.emit("skill/changed")
    await published
    expect(skillUpdates()).toEqual([
      expect.objectContaining({ skills: [expect.objectContaining({ invocation: "/new" })] })
    ])
  })

  it("maps items and ignores malformed ones", async () => {
    const { client, events } = await start()
    const at = events.length
    client.emit("item/started", {
      item: {
        itemId: "t1",
        kind: "toolCall",
        revision: 1,
        status: "inProgress",
        tool: "bash",
        args: "{}"
      }
    })
    client.emit("item/updated", { item: {} })
    client.emit("item/delta", { itemId: "t1", field: "output", delta: "ok" })
    client.emit("item/delta", { itemId: "t1" })
    client.emit("item/completed", {
      item: {
        itemId: "t1",
        kind: "toolCall",
        revision: 2,
        status: "completed",
        tool: "bash",
        args: "{}"
      }
    })
    expect(payloads(events.slice(at)).map((payload) => payload.sessionUpdate)).toEqual([
      "tool_call",
      "tool_call_update",
      "tool_call_update"
    ])
  })

  it("ends a running turn when a new prompt arrives or the chat closes", async () => {
    const { client, chat, events } = await start()
    const first = await send(chat, client, "first")
    // Muse queues the second prompt; the first one's caller is released.
    const second = await send(chat, client, "second")
    await expect(first.finished).resolves.toEqual({ stopReason: "end_turn" })
    chat.close()
    await expect(second.finished).resolves.toEqual({ stopReason: "cancelled" })
    expect(turns(events).map((turn) => turn.turnState)).toEqual([
      "started",
      "ended",
      "started",
      "ended"
    ])
    expect(client.closed).toBe(true)
  })

  it("reports Muse stopping mid-turn and closes its host", async () => {
    const { client, chat, events } = await start()
    const { finished } = await send(chat, client)
    client.crash(new Error("muse exited: out of memory"))
    await expect(finished).resolves.toEqual({ stopReason: "end_turn" })
    expect(events.find((event) => event.kind === "session.error")?.payload).toEqual({
      message: "muse exited: out of memory"
    })
    expect(turns(events).at(-1)).toMatchObject({ stopDetail: "muse exited: out of memory" })
    // Stopping again, with no turn running, only reports the error.
    const ended = turns(events).length
    client.crash(new Error("again"))
    expect(turns(events)).toHaveLength(ended)
    chat.close()
    expect(client.closed).toBe(true)
  })
})
