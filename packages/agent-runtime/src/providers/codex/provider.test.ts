import { Effect } from "effect"
import { describe, expect, it } from "vitest"
import type { HarnessDefinition, ProviderEnvironment, RuntimeEvent } from "../../types.js"
import type { CodexClient, CodexSpawnRequest } from "./client.js"
import { makeCodexProvider } from "./provider.js"

const run = <A>(effect: Effect.Effect<A, unknown>): Promise<A> => Effect.runPromise(effect)

const definition: HarnessDefinition = {
  detectBinaries: ["codex"],
  id: "codex",
  name: "Codex",
  provider: "codex",
  symbolName: "chevron.left.forwardslash.chevron.right"
}

const environment: ProviderEnvironment = {
  env: { PATH: "/bin" },
  executableExists: (name) => name === "codex",
  locateExecutable: (name) => (name === "codex" ? "/bin/codex" : undefined)
}

class FakeCodexClient implements CodexClient {
  readonly requests: Array<{ method: string; params: unknown }> = []
  readonly notifications: Array<{ method: string; params: unknown }> = []
  private notificationHandler: ((method: string, params: unknown) => void) | undefined
  private requestHandler: ((method: string, params: unknown) => Promise<unknown>) | undefined
  closed = false
  failResume = false

  async request<T>(method: string, params?: unknown): Promise<T> {
    this.requests.push({ method, params })
    switch (method) {
      case "initialize":
        return {} as T
      case "thread/start":
        return { model: "gpt-5.2-codex", thread: { id: "thread-new" } } as T
      case "thread/resume":
        if (this.failResume) {
          throw new Error("thread not found")
        }
        return { model: "gpt-5.2-codex", thread: { id: "thread-resumed" } } as T
      case "turn/start":
        return { turn: { id: "turn-1", status: "inProgress" } } as T
      case "turn/interrupt":
        return {} as T
      case "model/list":
        return {
          data: [
            {
              defaultReasoningEffort: "medium",
              description: "",
              displayName: "GPT-5.2 Codex",
              hidden: false,
              id: "gpt-5.2-codex",
              model: "gpt-5.2-codex",
              supportedReasoningEfforts: [
                { description: "", reasoningEffort: "low" },
                { description: "", reasoningEffort: "medium" },
                { description: "", reasoningEffort: "xhigh" }
              ]
            },
            {
              defaultReasoningEffort: "high",
              description: "",
              displayName: "GPT-5.5",
              hidden: false,
              id: "gpt-5.5",
              model: "gpt-5.5",
              supportedReasoningEfforts: [
                { description: "", reasoningEffort: "medium" },
                { description: "", reasoningEffort: "high" }
              ]
            },
            {
              displayName: "Hidden model",
              hidden: true,
              id: "secret",
              model: "secret"
            }
          ]
        } as T
      default:
        throw new Error(`Unexpected request: ${method}`)
    }
  }

  notify(method: string, params?: unknown): void {
    this.notifications.push({ method, params })
  }

  onNotification(handler: (method: string, params: unknown) => void): void {
    this.notificationHandler = handler
  }

  onRequest(handler: (method: string, params: unknown) => Promise<unknown>): void {
    this.requestHandler = handler
  }

  onClose(): void {}

  close(): void {
    this.closed = true
  }

  emit(method: string, params: unknown): void {
    this.notificationHandler?.(method, params)
  }

  async serverRequest(method: string, params: unknown): Promise<unknown> {
    if (this.requestHandler === undefined) throw new Error("no request handler")
    return this.requestHandler(method, params)
  }
}

const setup = async (options: { failResume?: boolean; resume?: string } = {}) => {
  const client = new FakeCodexClient()
  client.failResume = options.failResume ?? false
  const spawns: Array<CodexSpawnRequest> = []
  const provider = makeCodexProvider(environment, {
    connector: async (request) => {
      spawns.push(request)
      return client
    }
  })
  const events: Array<RuntimeEvent> = []
  const emit = async (event: RuntimeEvent): Promise<void> => {
    events.push(event)
  }
  const created =
    options.resume === undefined
      ? await run(provider.createSession(definition, "/tmp/project", emit))
      : undefined
  const loaded =
    options.resume === undefined
      ? undefined
      : await run(provider.loadSession(definition, options.resume, "/tmp/project", emit))
  return { client, created, events, loaded, provider, spawns }
}

const UNIFIED_DIFF = ["--- a/release.yml", "+++ b/release.yml", "@@ -1,3 +1,4 @@", " keep", "-old", "+new", "+extra"].join(
  "\n"
)

describe("CodexProvider", () => {
  it("handshakes, starts a thread, and reports config options", async () => {
    const { client, created, spawns } = await setup()
    expect(spawns[0]).toMatchObject({ command: "/bin/codex", cwd: "/tmp/project" })
    expect(client.requests.map((request) => request.method)).toEqual([
      "initialize",
      "thread/start",
      "model/list"
    ])
    expect(client.notifications).toEqual([{ method: "initialized", params: undefined }])
    expect(created?.metadata.sessionId).toBe("thread-new")
    const options = created?.metadata.configOptions ?? []
    const modelOption = options.find((option) => option.id === "model")
    expect(modelOption?.currentValue).toBe("gpt-5.2-codex")
    // Full catalog minus hidden models.
    expect(modelOption?.options.map((option) => ("value" in option ? option.value : ""))).toEqual([
      "gpt-5.2-codex",
      "gpt-5.5"
    ])
    // Efforts come from the current model's capabilities, defaulted per model.
    const effortOption = options.find((option) => option.id === "effort")
    expect(effortOption?.currentValue).toBe("medium")
    expect(effortOption?.options.map((option) => ("value" in option ? option.value : ""))).toEqual([
      "low",
      "medium",
      "xhigh"
    ])
    // Approval/sandbox presets are exposed as session modes.
    expect(created?.metadata.modes?.currentModeId).toBe("agent")
    expect(created?.metadata.modes?.availableModes.map((mode) => mode.id)).toEqual([
      "read-only",
      "agent",
      "agent-full-access"
    ])
  })

  it("applies modes as approval/sandbox turn overrides and syncs effort to the model", async () => {
    const { client, created, events } = await setup()
    await run(created!.handle.setMode("agent-full-access"))
    expect(events.at(-1)?.payload).toMatchObject({ modeId: "agent-full-access" })
    await expect(run(created!.handle.setMode("nonsense"))).rejects.toThrow("Unknown Codex mode")

    // An effort the new model doesn't support clamps to that model's default;
    // xhigh is valid for gpt-5.2-codex but not gpt-5.5.
    await run(created!.handle.setConfigOption("effort", "xhigh"))
    await run(created!.handle.setConfigOption("model", "gpt-5.5"))
    const promptPromise = run(created!.handle.prompt("go"))
    await Promise.resolve()
    client.emit("turn/completed", { threadId: "thread-new", turn: { id: "t", status: "completed" } })
    await promptPromise
    const turnStart = client.requests.find((request) => request.method === "turn/start")
    expect(turnStart?.params).toMatchObject({
      approvalPolicy: "never",
      effort: "high",
      model: "gpt-5.5",
      sandboxPolicy: { type: "dangerFullAccess" }
    })
  })

  it("maps a full turn: lifecycle, streamed patch stats, command items", async () => {
    const { client, created, events } = await setup()
    const promptPromise = run(created!.handle.prompt("change the runner"))
    await Promise.resolve()

    client.emit("turn/started", { threadId: "thread-new", turn: { id: "turn-1", status: "inProgress" } })
    client.emit("item/started", {
      item: { command: "rg runner", id: "item-cmd", status: "inProgress", type: "commandExecution" },
      threadId: "thread-new",
      turnId: "turn-1"
    })
    client.emit("item/completed", {
      item: {
        aggregatedOutput: "release.yml",
        command: "rg runner",
        exitCode: 0,
        id: "item-cmd",
        status: "completed",
        type: "commandExecution"
      },
      threadId: "thread-new",
      turnId: "turn-1"
    })
    client.emit("item/started", {
      item: { changes: [], id: "item-edit", status: "inProgress", type: "fileChange" },
      threadId: "thread-new",
      turnId: "turn-1"
    })
    client.emit("item/fileChange/patchUpdated", {
      changes: [{ diff: UNIFIED_DIFF, kind: { type: "update" }, path: "release.yml" }],
      itemId: "item-edit",
      threadId: "thread-new",
      turnId: "turn-1"
    })
    client.emit("item/completed", {
      item: {
        changes: [{ diff: UNIFIED_DIFF, kind: { type: "update" }, path: "release.yml" }],
        id: "item-edit",
        status: "completed",
        type: "fileChange"
      },
      threadId: "thread-new",
      turnId: "turn-1"
    })
    client.emit("item/agentMessage/delta", {
      delta: "Updated the runner.",
      itemId: "item-msg",
      threadId: "thread-new",
      turnId: "turn-1"
    })
    client.emit("turn/completed", {
      threadId: "thread-new",
      turn: { id: "turn-1", status: "completed" }
    })

    const result = await promptPromise
    expect(result.stopReason).toBe("end_turn")

    const payloads = events.map((event) => event.payload as Record<string, unknown>)
    expect(payloads[0]).toMatchObject({ initiatedBy: "user", turnId: "turn-1", turnState: "started" })
    expect(payloads).toContainEqual(
      expect.objectContaining({
        sessionUpdate: "tool_call",
        toolCallId: "item-cmd",
        kind: "execute",
        status: "in_progress",
        title: "Ran rg runner"
      })
    )
    expect(payloads).toContainEqual(
      expect.objectContaining({
        sessionUpdate: "tool_call_update",
        toolCallId: "item-cmd",
        status: "completed",
        rawOutput: "release.yml"
      })
    )
    // The streamed patch carries realtime per-file stats.
    const streamed = payloads.find(
      (payload) =>
        payload.sessionUpdate === "tool_call_update" &&
        payload.toolCallId === "item-edit" &&
        payload.status === "in_progress"
    )
    expect(streamed?.diffStats).toEqual([{ added: 2, path: "release.yml", removed: 1 }])
    // Completion carries final stats plus a renderable diff block.
    const completedEdit = payloads.find(
      (payload) =>
        payload.sessionUpdate === "tool_call_update" &&
        payload.toolCallId === "item-edit" &&
        payload.status === "completed"
    )
    expect(completedEdit?.diffStats).toEqual([{ added: 2, path: "release.yml", removed: 1 }])
    expect(Array.isArray(completedEdit?.content)).toBe(true)
    expect(payloads).toContainEqual(
      expect.objectContaining({ sessionUpdate: "agent_message_chunk", messageId: "item-msg" })
    )
    expect(payloads.at(-1)).toMatchObject({
      stopReason: "end_turn",
      turnId: "turn-1",
      turnState: "ended"
    })
  })

  it("opens the tool call from the first streamed patch update (arrives before item/started)", async () => {
    const { client, events } = await setup()
    client.emit("item/fileChange/patchUpdated", {
      changes: [{ diff: UNIFIED_DIFF, kind: { type: "update" }, path: "release.yml" }],
      itemId: "item-early",
      threadId: "thread-new",
      turnId: "turn-1"
    })
    const opened = events.at(-1)?.payload as Record<string, unknown>
    expect(opened).toMatchObject({
      sessionUpdate: "tool_call",
      toolCallId: "item-early",
      kind: "edit",
      status: "in_progress",
      title: "Editing release.yml",
      diffStats: [{ added: 2, path: "release.yml", removed: 1 }]
    })

    client.emit("item/fileChange/patchUpdated", {
      changes: [{ diff: UNIFIED_DIFF + "\n+more", kind: { type: "update" }, path: "release.yml" }],
      itemId: "item-early",
      threadId: "thread-new",
      turnId: "turn-1"
    })
    const streamed = events.at(-1)?.payload as Record<string, unknown>
    expect(streamed).toMatchObject({
      sessionUpdate: "tool_call_update",
      toolCallId: "item-early",
      status: "in_progress",
      diffStats: [{ added: 3, path: "release.yml", removed: 1 }]
    })

    // item/started for the same id merges rather than duplicating.
    client.emit("item/started", {
      item: {
        changes: [{ diff: UNIFIED_DIFF, kind: { type: "update" }, path: "release.yml" }],
        id: "item-early",
        status: "inProgress",
        type: "fileChange"
      },
      threadId: "thread-new",
      turnId: "turn-1"
    })
    expect((events.at(-1)?.payload as Record<string, unknown>).sessionUpdate).toBe("tool_call")
  })

  it("counts add/delete changes from raw content, updates from unified diffs", async () => {
    const { client, events } = await setup()
    client.emit("item/fileChange/patchUpdated", {
      changes: [{ diff: "one\ntwo\nthree\n", kind: { type: "add" }, path: "new.txt" }],
      itemId: "item-add",
      threadId: "thread-new",
      turnId: "turn-1"
    })
    expect((events.at(-1)?.payload as Record<string, unknown>).diffStats).toEqual([
      { added: 3, path: "new.txt", removed: 0 }
    ])
    client.emit("item/completed", {
      item: {
        changes: [{ diff: "one\ntwo\nthree\n", kind: { type: "delete" }, path: "old.txt" }],
        id: "item-del",
        status: "completed",
        type: "fileChange"
      },
      threadId: "thread-new",
      turnId: "turn-1"
    })
    const deleted = events.at(-1)?.payload as Record<string, unknown>
    expect(deleted.diffStats).toEqual([{ added: 0, path: "old.txt", removed: 3 }])
    expect(deleted.content).toEqual([
      { newText: "", oldText: "one\ntwo\nthree\n", path: "old.txt", type: "diff" }
    ])
  })

  it("drives the thinking state from reasoning item lifecycles", async () => {
    const { client, events } = await setup()
    client.emit("item/started", {
      item: { id: "rs_1", type: "reasoning" },
      threadId: "thread-new",
      turnId: "turn-1"
    })
    expect(events.at(-1)?.payload).toMatchObject({ sessionUpdate: "agent_thought_chunk" })
    // Completion emits nothing extra; the next message/tool clears the state
    // client-side.
    const count = events.length
    client.emit("item/completed", {
      item: { id: "rs_1", summary: [], type: "reasoning" },
      threadId: "thread-new",
      turnId: "turn-1"
    })
    expect(events.length).toBe(count)
  })

  it("interrupts: turn/interrupt is sent and the turn ends cancelled", async () => {
    const { client, created, events } = await setup()
    const promptPromise = run(created!.handle.prompt("long work"))
    await Promise.resolve()
    client.emit("turn/started", { threadId: "thread-new", turn: { id: "turn-9", status: "inProgress" } })
    await Promise.resolve()

    await run(created!.handle.cancel)
    expect(client.requests.at(-1)).toMatchObject({
      method: "turn/interrupt",
      params: { threadId: "thread-new", turnId: "turn-9" }
    })
    client.emit("turn/completed", {
      threadId: "thread-new",
      turn: { id: "turn-9", status: "interrupted" }
    })
    const result = await promptPromise
    expect(result.stopReason).toBe("cancelled")
    expect(events.every((event) => event.kind !== "session.error")).toBe(true)
  })

  it("auto-accepts approval requests", async () => {
    const { client } = await setup()
    await expect(
      client.serverRequest("item/commandExecution/requestApproval", { itemId: "x" })
    ).resolves.toEqual({ decision: "accept" })
    await expect(
      client.serverRequest("item/fileChange/requestApproval", { itemId: "x" })
    ).resolves.toEqual({ decision: "accept" })
    await expect(client.serverRequest("something/else", {})).rejects.toThrow(
      "Unsupported approval request"
    )
  })

  it("keeps the requested id when resuming, with thread/start fallback", async () => {
    const { client, loaded } = await setup({ resume: "old-thread" })
    expect(loaded?.sessionId).toBe("old-thread")
    expect(client.requests.map((request) => request.method)).toContain("thread/resume")

    const fallback = await setup({ failResume: true, resume: "not-a-thread" })
    expect(fallback.loaded?.sessionId).toBe("not-a-thread")
    expect(fallback.client.requests.map((request) => request.method)).toContain("thread/start")
  })

  it("applies model/effort overrides as sticky turn/start params", async () => {
    const { client, created } = await setup()
    const events: Array<RuntimeEvent> = []
    void events
    await run(created!.handle.setConfigOption("effort", "high"))
    const promptPromise = run(created!.handle.prompt("go"))
    await Promise.resolve()
    client.emit("turn/completed", { threadId: "thread-new", turn: { id: "t", status: "completed" } })
    await promptPromise
    const turnStart = client.requests.find((request) => request.method === "turn/start")
    expect(turnStart?.params).toMatchObject({ effort: "high", model: "gpt-5.2-codex" })
  })

  it("reports readiness from binary presence", () => {
    const provider = makeCodexProvider(environment)
    expect(provider.readiness(definition)).toEqual({ state: "ready" })
    const missing = makeCodexProvider({
      env: {},
      executableExists: () => false,
      locateExecutable: () => undefined
    })
    expect(missing.readiness(definition)).toEqual({
      detail: "CLI not found on PATH",
      state: "unavailable"
    })
  })
})
