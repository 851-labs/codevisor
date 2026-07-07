import { Effect } from "effect"
import { afterEach, describe, expect, it, vi } from "vitest"
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
  readonly pid = 4242
  readonly requests: Array<{ method: string; params: unknown }> = []
  readonly notifications: Array<{ method: string; params: unknown }> = []
  private notificationHandler: ((method: string, params: unknown) => void) | undefined
  private requestHandler: ((method: string, params: unknown) => Promise<unknown>) | undefined
  closed = false
  failResume = false
  goal:
    | {
        createdAt: number
        objective: string
        status: string
        threadId: string
        timeUsedSeconds: number
        tokenBudget: number | null
        tokensUsed: number
        updatedAt: number
      }
    | undefined

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
      case "thread/goal/set": {
        const update = params as {
          objective?: string
          status?: string
          tokenBudget?: number | null
        }
        this.goal = {
          createdAt: this.goal?.createdAt ?? 1_700_000_000,
          objective: update.objective ?? this.goal?.objective ?? "existing objective",
          status: update.status ?? this.goal?.status ?? "active",
          threadId: "thread-new",
          timeUsedSeconds: this.goal?.timeUsedSeconds ?? 0,
          tokenBudget:
            "tokenBudget" in update ? update.tokenBudget! : (this.goal?.tokenBudget ?? null),
          tokensUsed: this.goal?.tokensUsed ?? 0,
          updatedAt: 1_700_000_100
        }
        return { goal: this.goal } as T
      }
      case "thread/goal/clear": {
        const cleared = this.goal !== undefined
        this.goal = undefined
        return { cleared } as T
      }
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
              serviceTiers: [
                { description: "Faster processing", id: "priority", name: "Priority" }
              ],
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

const UNIFIED_DIFF = [
  "--- a/release.yml",
  "+++ b/release.yml",
  "@@ -1,3 +1,4 @@",
  " keep",
  "-old",
  "+new",
  "+extra"
].join("\n")

describe("CodexProvider", () => {
  afterEach(() => {
    vi.useRealTimers()
  })

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
    // Approval/sandbox presets are exposed as session modes; full access is
    // the default posture.
    expect(created?.metadata.modes?.currentModeId).toBe("agent-full-access")
    expect(created?.metadata.modes?.availableModes.map((mode) => mode.id)).toEqual([
      "plan",
      "read-only",
      "agent",
      "agent-full-access"
    ])
    expect(created?.metadata.modes?.availableModes.map((mode) => mode.canonicalId)).toEqual([
      "plan",
      "readOnly",
      "ask",
      "fullAccess"
    ])
    // Experimental APIs (collaborationMode, requestUserInput) are opted into
    // at initialize.
    expect(client.requests[0]).toMatchObject({
      method: "initialize",
      params: { capabilities: { experimentalApi: true } }
    })
  })

  it("plan mode sends the experimental collaboration mode on turn/start", async () => {
    const { client, created } = await setup()
    await run(created!.handle.setMode("plan"))
    const promptPromise = run(created!.handle.prompt("plan this"))
    await Promise.resolve()
    client.emit("turn/completed", {
      threadId: "thread-new",
      turn: { id: "t-plan", status: "completed" }
    })
    await promptPromise
    const turnStart = client.requests.find((request) => request.method === "turn/start")
    expect(turnStart?.params).toMatchObject({
      approvalPolicy: "on-request",
      collaborationMode: {
        mode: "plan",
        settings: {
          developer_instructions: null,
          model: "gpt-5.2-codex",
          reasoning_effort: "medium"
        }
      },
      sandboxPolicy: { networkAccess: false, type: "readOnly" }
    })
    // Non-plan modes never send collaborationMode.
    await run(created!.handle.setMode("agent"))
    const secondPrompt = run(created!.handle.prompt("implement"))
    await Promise.resolve()
    client.emit("turn/completed", {
      threadId: "thread-new",
      turn: { id: "t-agent", status: "completed" }
    })
    await secondPrompt
    const secondStart = client.requests.filter((request) => request.method === "turn/start").at(-1)
    expect(secondStart?.params).not.toHaveProperty("collaborationMode")
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
    client.emit("turn/completed", {
      threadId: "thread-new",
      turn: { id: "t", status: "completed" }
    })
    await promptPromise
    const turnStart = client.requests.find((request) => request.method === "turn/start")
    expect(turnStart?.params).toMatchObject({
      approvalPolicy: "never",
      effort: "high",
      model: "gpt-5.5",
      sandboxPolicy: { type: "dangerFullAccess" }
    })
  })

  it("exposes speed for priority-tier models and applies it as a turn override", async () => {
    const { client, created, events } = await setup()
    const speedOption = created?.metadata.configOptions.find((option) => option.id === "speed")
    expect(speedOption).toMatchObject({
      category: "speed",
      currentValue: "standard",
      name: "Speed"
    })

    const runTurn = async (text: string, turnId: string): Promise<void> => {
      const promptPromise = run(created!.handle.prompt(text))
      await Promise.resolve()
      client.emit("turn/completed", {
        threadId: "thread-new",
        turn: { id: turnId, status: "completed" }
      })
      await promptPromise
    }
    const lastTurnStart = (): Record<string, unknown> =>
      client.requests.filter((request) => request.method === "turn/start").at(-1)?.params as Record<
        string,
        unknown
      >

    await run(created!.handle.setConfigOption("speed", "fast"))
    expect(events.at(-1)?.payload).toMatchObject({ configId: "speed", value: "fast" })
    await runTurn("go fast", "t1")
    expect(lastTurnStart()).toMatchObject({ serviceTier: "priority" })

    // Standard routes via the explicit "default" sentinel, not an omission.
    await run(created!.handle.setConfigOption("speed", "standard"))
    await runTurn("go normal", "t2")
    expect(lastTurnStart()).toMatchObject({ serviceTier: "default" })

    // A model without a fast tier drops the option and the tier override.
    await run(created!.handle.setConfigOption("model", "gpt-5.5"))
    const afterModel = events.at(-1)?.payload as { configOptions?: Array<{ id: string }> }
    expect(afterModel.configOptions).not.toContainEqual(expect.objectContaining({ id: "speed" }))
    await runTurn("go", "t3")
    expect("serviceTier" in lastTurnStart()).toBe(false)
  })

  it("maps attachments: images as localImage paths, files as path notes", async () => {
    const { client, created } = await setup()
    const promptPromise = run(
      created!.handle.prompt({
        text: "check these",
        attachments: [
          {
            data: Buffer.from("png"),
            kind: "image",
            mimeType: "image/png",
            name: "shot.png",
            path: "/tmp/att/shot.png"
          },
          {
            data: Buffer.from("csv"),
            kind: "file",
            mimeType: "text/csv",
            name: "data.csv",
            path: "/tmp/att/data.csv"
          }
        ]
      })
    )
    await Promise.resolve()
    client.emit("turn/completed", {
      threadId: "thread-new",
      turn: { id: "turn-att", status: "completed" }
    })
    await promptPromise
    const turnStart = client.requests.find((request) => request.method === "turn/start")
    expect(turnStart?.params).toMatchObject({
      input: [
        {
          text: "check these\n\n[Attached file: /tmp/att/data.csv (data.csv, text/csv)]",
          type: "text"
        },
        { path: "/tmp/att/shot.png", type: "localImage" }
      ]
    })
  })

  it("sends an image-only prompt without a text item", async () => {
    const { client, created } = await setup()
    const promptPromise = run(
      created!.handle.prompt({
        text: "",
        attachments: [
          {
            data: Buffer.from("png"),
            kind: "image",
            mimeType: "image/png",
            name: "only.png",
            path: "/tmp/att/only.png"
          }
        ]
      })
    )
    await Promise.resolve()
    client.emit("turn/completed", {
      threadId: "thread-new",
      turn: { id: "turn-img", status: "completed" }
    })
    await promptPromise
    const turnStart = client.requests.find((request) => request.method === "turn/start")
    expect(turnStart?.params).toMatchObject({
      input: [{ path: "/tmp/att/only.png", type: "localImage" }]
    })
  })

  it("mirrors command output into background terminals and promotes long-lived commands", async () => {
    vi.useFakeTimers()
    const client = new FakeCodexClient()
    const kills: Array<{ rootPid: number; command: string }> = []
    const registered: Array<{
      key: string
      outputs: Array<string>
      exits: Array<number | undefined>
      removed: boolean
      kill: (() => void) | undefined
    }> = []
    const provider = makeCodexProvider(environment, {
      backgroundTerminals: {
        promotionDelayMs: 50,
        registry: {
          register: (key, controls) => {
            const entry = {
              exits: [],
              key,
              kill: controls.kill,
              outputs: [],
              removed: false
            } as (typeof registered)[0]
            registered.push(entry)
            return {
              exit: (exitCode) => entry.exits.push(exitCode),
              output: (data) => entry.outputs.push(data),
              remove: () => {
                entry.removed = true
              }
            }
          }
        }
      },
      connector: async () => client,
      killCommandProcesses: async (rootPid, command) => {
        kills.push({ command, rootPid })
      }
    })
    const events: Array<RuntimeEvent> = []
    const created = await run(
      provider.createSession(definition, "/tmp/project", async (event) => {
        events.push(event)
      })
    )
    const snapshots = () =>
      events
        .filter((event) => event.kind === "session.updated")
        .map((event) => event.payload as Record<string, unknown>)
        .filter((payload) => Array.isArray(payload.backgroundTasks))
        .map((payload) => payload.backgroundTasks as Array<Record<string, unknown>>)
    // Session creation clears any stale replayed snapshot.
    expect(snapshots()).toEqual([[]])

    client.emit("item/started", {
      item: {
        command: "npm run dev",
        id: "item-dev",
        status: "inProgress",
        type: "commandExecution"
      },
      threadId: "thread-new",
      turnId: "turn-1"
    })
    client.emit("item/commandExecution/outputDelta", {
      delta: "ready on :3000\n",
      itemId: "item-dev",
      threadId: "thread-new",
      turnId: "turn-1"
    })
    // Deltas for unknown items are dropped.
    client.emit("item/commandExecution/outputDelta", {
      delta: "noise",
      itemId: "item-unknown",
      threadId: "thread-new",
      turnId: "turn-1"
    })
    expect(registered[0]?.key).toBe("thread-new:bg:item-dev")
    expect(registered[0]?.outputs).toEqual(["ready on :3000\n"])

    // The mirror's kill control walks the codex process tree (best effort).
    registered[0]?.kill?.()
    expect(kills).toEqual([{ command: "npm run dev", rootPid: 4242 }])

    // Still running after the promotion delay → surfaces as a task with a
    // terminal key.
    vi.advanceTimersByTime(50)
    expect(snapshots().at(-1)).toEqual([
      {
        description: "npm run dev",
        id: "item-dev",
        readOnly: true,
        status: "running",
        taskType: "shell",
        terminalKey: "thread-new:bg:item-dev",
        toolUseId: "item-dev"
      }
    ])

    // Completion ends the mirror, clears the task, and keeps the scrollback.
    client.emit("item/completed", {
      item: {
        command: "npm run dev",
        exitCode: 0,
        id: "item-dev",
        status: "completed",
        type: "commandExecution"
      },
      threadId: "thread-new",
      turnId: "turn-1"
    })
    expect(registered[0]?.exits).toEqual([0])
    expect(registered[0]?.removed).toBe(false)
    expect(snapshots().at(-1)).toEqual([])

    // A short-lived command never surfaces and leaves nothing behind.
    client.emit("item/started", {
      item: { command: "ls", id: "item-ls", status: "inProgress", type: "commandExecution" },
      threadId: "thread-new",
      turnId: "turn-1"
    })
    client.emit("item/completed", {
      item: { command: "ls", id: "item-ls", status: "completed", type: "commandExecution" },
      threadId: "thread-new",
      turnId: "turn-1"
    })
    expect(registered[1]?.exits).toEqual([undefined])
    expect(registered[1]?.removed).toBe(true)
    vi.advanceTimersByTime(1000)
    expect(snapshots().at(-1)).toEqual([])

    // unifiedExecStartup is codex explicitly opening a persistent shell — it
    // surfaces as a task immediately, no promotion delay.
    client.emit("item/started", {
      item: {
        command: "npm run watch",
        id: "item-watch",
        source: "unifiedExecStartup",
        status: "inProgress",
        type: "commandExecution"
      },
      threadId: "thread-new",
      turnId: "turn-1"
    })
    expect(snapshots().at(-1)).toEqual([
      {
        description: "npm run watch",
        id: "item-watch",
        readOnly: true,
        status: "running",
        taskType: "shell",
        terminalKey: "thread-new:bg:item-watch",
        toolUseId: "item-watch"
      }
    ])
    client.emit("item/completed", {
      item: {
        command: "npm run watch",
        exitCode: 0,
        id: "item-watch",
        source: "unifiedExecStartup",
        status: "completed",
        type: "commandExecution"
      },
      threadId: "thread-new",
      turnId: "turn-1"
    })
    expect(snapshots().at(-1)).toEqual([])

    // Session close ends any mirrors that are still running.
    client.emit("item/started", {
      item: { command: "sleep 99", id: "item-zzz", status: "inProgress", type: "commandExecution" },
      threadId: "thread-new",
      turnId: "turn-1"
    })
    await run(created.handle.close)
    expect(registered[3]?.exits).toEqual([undefined])
    expect(registered[3]?.removed).toBe(true)
  })

  it("maps a full turn: lifecycle, streamed patch stats, command items", async () => {
    const { client, created, events } = await setup()
    const promptPromise = run(created!.handle.prompt("change the runner"))
    await Promise.resolve()

    client.emit("turn/started", {
      threadId: "thread-new",
      turn: { id: "turn-1", status: "inProgress" }
    })
    client.emit("item/started", {
      item: {
        command: "rg runner",
        id: "item-cmd",
        status: "inProgress",
        type: "commandExecution"
      },
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
    expect(payloads[0]).toMatchObject({
      initiatedBy: "user",
      turnId: "turn-1",
      turnState: "started"
    })
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

  it("carries agentMessage phase from item/started onto chunks and retro-tags completion-only phases", async () => {
    const { client, created, events } = await setup()
    const promptPromise = run(created!.handle.prompt("finality"))
    await Promise.resolve()

    client.emit("turn/started", {
      threadId: "thread-new",
      turn: { id: "turn-1", status: "inProgress" }
    })
    // Commentary preamble tagged at item/started: chunks carry the phase.
    client.emit("item/started", {
      item: { content: [], id: "item-pre", phase: "commentary", type: "agentMessage" },
      threadId: "thread-new",
      turnId: "turn-1"
    })
    client.emit("item/agentMessage/delta", {
      delta: "Checking the workflow first.",
      itemId: "item-pre",
      threadId: "thread-new",
      turnId: "turn-1"
    })
    client.emit("item/completed", {
      item: { content: [], id: "item-pre", phase: "commentary", type: "agentMessage" },
      threadId: "thread-new",
      turnId: "turn-1"
    })
    // Final answer tagged at item/started: chunks stream as final from the start.
    client.emit("item/started", {
      item: { content: [], id: "item-final", phase: "final_answer", type: "agentMessage" },
      threadId: "thread-new",
      turnId: "turn-1"
    })
    client.emit("item/agentMessage/delta", {
      delta: "All done.",
      itemId: "item-final",
      threadId: "thread-new",
      turnId: "turn-1"
    })
    client.emit("item/completed", {
      item: { content: [], id: "item-final", phase: "final_answer", type: "agentMessage" },
      threadId: "thread-new",
      turnId: "turn-1"
    })
    // Untagged at start, tagged only on completion: a zero-length chunk
    // retro-tags the already-streamed span.
    client.emit("item/started", {
      item: { content: [], id: "item-late", type: "agentMessage" },
      threadId: "thread-new",
      turnId: "turn-1"
    })
    client.emit("item/agentMessage/delta", {
      delta: "Actually, one more thing…",
      itemId: "item-late",
      threadId: "thread-new",
      turnId: "turn-1"
    })
    client.emit("item/completed", {
      item: { content: [], id: "item-late", phase: "commentary", type: "agentMessage" },
      threadId: "thread-new",
      turnId: "turn-1"
    })
    client.emit("turn/completed", {
      threadId: "thread-new",
      turn: { id: "turn-1", status: "completed" }
    })
    await promptPromise

    const payloads = events.map((event) => event.payload as Record<string, unknown>)
    expect(payloads).toContainEqual(
      expect.objectContaining({
        content: { text: "Checking the workflow first.", type: "text" },
        messageId: "item-pre",
        phase: "commentary",
        sessionUpdate: "agent_message_chunk"
      })
    )
    expect(payloads).toContainEqual(
      expect.objectContaining({
        content: { text: "All done.", type: "text" },
        messageId: "item-final",
        phase: "final",
        sessionUpdate: "agent_message_chunk"
      })
    )
    // The untagged stream carried no phase…
    const lateChunks = payloads.filter(
      (payload) =>
        payload.sessionUpdate === "agent_message_chunk" && payload.messageId === "item-late"
    )
    expect(lateChunks[0]).not.toHaveProperty("phase")
    // …and completion retro-tagged it with a zero-length correction chunk.
    expect(lateChunks.at(-1)).toMatchObject({
      content: { text: "", type: "text" },
      phase: "commentary"
    })
    // Matching phases at start and completion emit no redundant correction.
    const finalChunks = payloads.filter(
      (payload) =>
        payload.sessionUpdate === "agent_message_chunk" && payload.messageId === "item-final"
    )
    expect(finalChunks).toHaveLength(1)
  })

  it("nests collab subagent threads under the spawn call and isolates their turn lifecycle", async () => {
    const { client, created, events } = await setup()
    const promptPromise = run(created!.handle.prompt("spin up subagents"))
    await Promise.resolve()

    client.emit("turn/started", {
      threadId: "thread-new",
      turn: { id: "turn-1", status: "inProgress" }
    })
    // spawnAgent opens the Agent tool call and registers the child thread.
    client.emit("item/started", {
      item: {
        agentsStates: {},
        id: "collab-spawn",
        prompt: "Explore the repo\nreport back",
        receiverThreadIds: ["thread-child"],
        senderThreadId: "thread-new",
        status: "inProgress",
        tool: "spawnAgent",
        type: "collabAgentToolCall"
      },
      threadId: "thread-new",
      turnId: "turn-1"
    })
    client.emit("item/completed", {
      item: {
        agentsStates: {},
        id: "collab-spawn",
        receiverThreadIds: ["thread-child"],
        senderThreadId: "thread-new",
        status: "completed",
        tool: "spawnAgent",
        type: "collabAgentToolCall"
      },
      threadId: "thread-new",
      turnId: "turn-1"
    })
    // The child thread works: its turn lifecycle must NOT drive the session's.
    client.emit("turn/started", {
      threadId: "thread-child",
      turn: { id: "turn-child", status: "inProgress" }
    })
    client.emit("item/started", {
      item: { command: "ls", id: "child-cmd", status: "inProgress", type: "commandExecution" },
      threadId: "thread-child",
      turnId: "turn-child"
    })
    client.emit("item/agentMessage/delta", {
      delta: "child findings",
      itemId: "child-msg",
      threadId: "thread-child",
      turnId: "turn-child"
    })
    // Traffic from a thread we can't attribute is dropped, not mixed in.
    client.emit("item/agentMessage/delta", {
      delta: "stranger danger",
      itemId: "stray-msg",
      threadId: "thread-stranger",
      turnId: "turn-x"
    })
    client.emit("turn/completed", {
      threadId: "thread-child",
      turn: { id: "turn-child", status: "completed" }
    })
    // closeAgent settles the spawn row.
    client.emit("item/completed", {
      item: {
        agentsStates: {},
        id: "collab-close",
        receiverThreadIds: ["thread-child"],
        senderThreadId: "thread-new",
        status: "completed",
        tool: "closeAgent",
        type: "collabAgentToolCall"
      },
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
    expect(payloads).toContainEqual(
      expect.objectContaining({
        kind: "agent",
        sessionUpdate: "tool_call",
        status: "in_progress",
        title: "Agent: Explore the repo",
        toolCallId: "collab-spawn"
      })
    )
    expect(payloads).toContainEqual(
      expect.objectContaining({
        parentToolCallId: "collab-spawn",
        sessionUpdate: "tool_call",
        toolCallId: "child-cmd"
      })
    )
    expect(payloads).toContainEqual(
      expect.objectContaining({
        messageId: "child-msg",
        parentToolCallId: "collab-spawn",
        sessionUpdate: "agent_message_chunk"
      })
    )
    expect(payloads).toContainEqual(
      expect.objectContaining({
        sessionUpdate: "tool_call_update",
        status: "completed",
        toolCallId: "collab-spawn"
      })
    )
    // No visible rows for the close call itself, no stray-thread leakage, and
    // exactly one turn end — the child's turn never ended the session's.
    expect(payloads.some((payload) => payload.toolCallId === "collab-close")).toBe(false)
    expect(JSON.stringify(payloads)).not.toContain("stranger danger")
    expect(payloads.filter((payload) => payload.turnState === "ended")).toHaveLength(1)
  })

  it("cuts long spawn prompts at a word boundary in the Agent title", async () => {
    const { client, events } = await setup()
    client.emit("item/started", {
      item: {
        agentsStates: {},
        id: "collab-long",
        prompt:
          "You are one of a couple sub-agents being spawned for a demonstration. Read-only task: inspect things.",
        receiverThreadIds: ["thread-child"],
        senderThreadId: "thread-new",
        status: "inProgress",
        tool: "spawnAgent",
        type: "collabAgentToolCall"
      },
      threadId: "thread-new",
      turnId: "turn-1"
    })
    await Promise.resolve()

    const spawn = events
      .map((event) => event.payload as Record<string, unknown>)
      .find((payload) => payload.toolCallId === "collab-long")
    expect(spawn?.title).toBe("Agent: You are one of a couple sub-agents being…")
  })

  it("cancels a spawned agent's row when its thread is interrupted", async () => {
    const { client, events } = await setup()
    client.emit("item/started", {
      item: {
        agentsStates: {},
        id: "collab-spawn",
        receiverThreadIds: ["thread-child"],
        senderThreadId: "thread-new",
        status: "inProgress",
        tool: "spawnAgent",
        type: "collabAgentToolCall"
      },
      threadId: "thread-new",
      turnId: "turn-1"
    })
    client.emit("item/completed", {
      item: {
        agentPath: "root/child",
        agentThreadId: "thread-child",
        id: "activity-1",
        kind: "interrupted",
        type: "subAgentActivity"
      },
      threadId: "thread-new",
      turnId: "turn-1"
    })
    await Promise.resolve()

    const payloads = events.map((event) => event.payload as Record<string, unknown>)
    expect(payloads).toContainEqual(
      expect.objectContaining({
        sessionUpdate: "tool_call_update",
        status: "cancelled",
        toolCallId: "collab-spawn"
      })
    )
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
    client.emit("turn/started", {
      threadId: "thread-new",
      turn: { id: "turn-9", status: "inProgress" }
    })
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

  it("rejects unknown server requests", async () => {
    const { client } = await setup()
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
    client.emit("turn/completed", {
      threadId: "thread-new",
      turn: { id: "t", status: "completed" }
    })
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

  it("falls back to the Codex.app bundled binary when the CLI is not on PATH", async () => {
    const bundled = "/Applications/Codex.app/Contents/Resources/codex"
    const appOnly: ProviderEnvironment = {
      env: { PATH: "/bin" },
      executableExists: (name) => name === bundled,
      locateExecutable: (name) => (name === bundled ? bundled : undefined)
    }
    const withFallback: HarnessDefinition = { ...definition, fallbackPaths: [bundled] }

    // Readiness sees the bundled binary even though PATH has nothing.
    const provider = makeCodexProvider(appOnly)
    expect(provider.readiness(withFallback)).toEqual({ state: "ready" })
    expect(provider.readiness(definition)).toEqual({
      detail: "CLI not found on PATH",
      state: "unavailable"
    })

    // Sessions spawn the bundled binary.
    const client = new FakeCodexClient()
    const spawns: Array<CodexSpawnRequest> = []
    const spawning = makeCodexProvider(appOnly, {
      connector: async (request) => {
        spawns.push(request)
        return client
      }
    })
    await run(spawning.createSession(withFallback, "/tmp/project", async () => {}))
    expect(spawns[0]).toMatchObject({ command: bundled, cwd: "/tmp/project" })

    // Neither PATH nor a bundle: session creation fails with a clear error.
    await expect(
      run(spawning.createSession(definition, "/tmp/project", async () => {}))
    ).rejects.toThrow("codex not found on PATH or in the Codex app")
  })

  it("holds requestUserInput open until answered, mapping notes onto the reply", async () => {
    const { client, created, events } = await setup()
    const request = client.serverRequest("item/tool/requestUserInput", {
      itemId: "item-q1",
      questions: [
        {
          header: "Approach",
          id: "approach",
          isOther: true,
          isSecret: false,
          options: [
            { description: "Fastest to ship.", label: "MVP first (Recommended)" },
            { description: "Safer long-term.", label: "Full design" }
          ],
          question: "Which approach should I take?"
        }
      ],
      threadId: "thread-new",
      turnId: "turn-1"
    })
    await Promise.resolve()
    const asked = events.at(-1)?.payload as Record<string, unknown>
    expect(asked).toMatchObject({
      questionId: "item-q1",
      sessionUpdate: "question"
    })
    expect(asked.questions).toEqual([
      {
        allowsOther: true,
        header: "Approach",
        id: "approach",
        options: [
          { description: "Fastest to ship.", label: "MVP first (Recommended)" },
          { description: "Safer long-term.", label: "Full design" }
        ],
        question: "Which approach should I take?"
      }
    ])

    await run(
      created!.handle.answerQuestion!("item-q1", {
        answers: { approach: { answers: ["MVP first (Recommended)"], note: "keep it small" } },
        outcome: "answered"
      })
    )
    await expect(request).resolves.toEqual({
      answers: { approach: { answers: ["MVP first (Recommended)", "user_note: keep it small"] } }
    })
    expect(events.at(-1)?.payload).toMatchObject({
      outcome: "answered",
      questionId: "item-q1",
      sessionUpdate: "question_resolved",
      answers: { approach: { answers: ["MVP first (Recommended)"], note: "keep it small" } }
    })

    // Answering again fails: the question is no longer pending.
    await expect(
      run(created!.handle.answerQuestion!("item-q1", { outcome: "answered" }))
    ).rejects.toThrow("No pending question")
  })

  it("cancel rejects the held question so the model sees it was dismissed", async () => {
    const { client, created, events } = await setup()
    const request = client.serverRequest("item/tool/requestUserInput", {
      itemId: "item-q2",
      questions: [{ id: "q", isOther: true, options: [{ label: "A" }], question: "Pick" }],
      threadId: "thread-new",
      turnId: "turn-1"
    })
    await Promise.resolve()
    await run(created!.handle.answerQuestion!("item-q2", { outcome: "cancelled" }))
    await expect(request).rejects.toThrow("dismissed")
    expect(events.at(-1)?.payload).toMatchObject({
      outcome: "cancelled",
      questionId: "item-q2",
      sessionUpdate: "question_resolved"
    })
  })

  it("auto-resolves timed questions with empty answers, codex-TUI style", async () => {
    vi.useFakeTimers()
    const { client, events } = await setup()
    const request = client.serverRequest("item/tool/requestUserInput", {
      autoResolutionMs: 60_000,
      itemId: "item-q3",
      questions: [{ id: "q", isOther: true, options: [{ label: "A" }], question: "Pick" }],
      threadId: "thread-new",
      turnId: "turn-1"
    })
    await Promise.resolve()
    vi.advanceTimersByTime(60_000)
    await expect(request).resolves.toEqual({ answers: {} })
    expect(events.at(-1)?.payload).toMatchObject({
      outcome: "autoResolved",
      questionId: "item-q3",
      sessionUpdate: "question_resolved"
    })
    vi.useRealTimers()
  })

  it("turn interrupt and turn completion cancel any held questions", async () => {
    const { client, created, events } = await setup()
    const promptPromise = run(created!.handle.prompt("go"))
    await Promise.resolve()
    client.emit("turn/started", { threadId: "thread-new", turn: { id: "turn-q" } })
    const request = client.serverRequest("item/tool/requestUserInput", {
      itemId: "item-q4",
      questions: [{ id: "q", isOther: true, options: [{ label: "A" }], question: "Pick" }],
      threadId: "thread-new",
      turnId: "turn-q"
    })
    await Promise.resolve()
    await run(created!.handle.cancel)
    await expect(request).rejects.toThrow("cancelled with the turn")
    expect(
      events.some((event) => {
        const payload = event.payload as Record<string, unknown>
        return payload.sessionUpdate === "question_resolved" && payload.outcome === "cancelled"
      })
    ).toBe(true)
    client.emit("turn/completed", {
      threadId: "thread-new",
      turn: { id: "turn-q", status: "interrupted" }
    })
    await promptPromise
  })

  it("maps MCP elicitation forms onto questions and coerces typed answers back", async () => {
    const { client, created, events } = await setup()
    const request = client.serverRequest("mcpServer/elicitation/request", {
      message: "GitHub needs a few details.",
      mode: "form",
      requestedSchema: {
        properties: {
          confirm: { title: "Proceed with login?", type: "boolean" },
          environment: {
            description: "Which environment?",
            oneOf: [
              { const: "prod", title: "Production" },
              { const: "stg", title: "Staging" }
            ],
            type: "string"
          },
          retries: { title: "Retry count", type: "integer" },
          token: { description: "Personal access token", type: "string" }
        },
        required: ["token"],
        type: "object"
      },
      serverName: "github",
      threadId: "thread-new",
      turnId: null
    })
    await Promise.resolve()
    const asked = events.at(-1)?.payload as Record<string, unknown>
    expect(asked.sessionUpdate).toBe("question")
    expect(asked.message).toBe("GitHub needs a few details.")
    const questionId = asked.questionId as string
    expect(asked.questions).toEqual([
      {
        allowsOther: false,
        id: "confirm",
        options: [{ label: "Yes" }, { label: "No" }],
        question: "Proceed with login?"
      },
      {
        allowsOther: false,
        id: "environment",
        options: [{ label: "Production" }, { label: "Staging" }],
        question: "Which environment?"
      },
      { allowsOther: true, id: "retries", options: [], question: "Retry count" },
      { allowsOther: true, id: "token", options: [], question: "Personal access token" }
    ])

    await run(
      created!.handle.answerQuestion!(questionId, {
        answers: {
          confirm: { answers: ["Yes"] },
          environment: { answers: ["Staging"] },
          retries: { answers: [], note: "3" },
          token: { answers: [], note: "ghp_secret" }
        },
        outcome: "answered"
      })
    )
    // Enum labels map back to const values; booleans and numbers coerce.
    await expect(request).resolves.toEqual({
      action: "accept",
      content: { confirm: true, environment: "stg", retries: 3, token: "ghp_secret" }
    })
  })

  it("cancels MCP elicitations with the MCP action and declines url mode", async () => {
    const { client, created, events } = await setup()
    const request = client.serverRequest("mcpServer/elicitation/request", {
      message: "Pick one.",
      mode: "form",
      requestedSchema: {
        properties: { choice: { enum: ["a", "b"], enumNames: ["Alpha", "Beta"], type: "string" } },
        type: "object"
      },
      serverName: "svc",
      threadId: "thread-new",
      turnId: null
    })
    await Promise.resolve()
    const asked = events.at(-1)?.payload as Record<string, unknown>
    expect(asked.questions).toEqual([
      {
        allowsOther: false,
        id: "choice",
        options: [{ label: "Alpha" }, { label: "Beta" }],
        question: "choice"
      }
    ])
    // Dismissing resolves with the MCP cancel action (never a JSON-RPC error).
    await run(created!.handle.answerQuestion!(asked.questionId as string, { outcome: "cancelled" }))
    await expect(request).resolves.toEqual({ action: "cancel", content: null })
    expect(events.at(-1)?.payload).toMatchObject({
      outcome: "cancelled",
      sessionUpdate: "question_resolved"
    })

    await expect(
      client.serverRequest("mcpServer/elicitation/request", {
        message: "Open this URL",
        mode: "url",
        serverName: "svc",
        threadId: "thread-new",
        turnId: null,
        url: "https://example.com/auth"
      })
    ).resolves.toEqual({ action: "decline", content: null })
  })

  it("surfaces approvals as Allow/Deny questions with item context", async () => {
    const { client, created, events } = await setup()
    // The item opens first; its command becomes the approval prompt's detail.
    client.emit("item/started", {
      item: {
        command: "rm -rf build",
        id: "cmd-1",
        status: "inProgress",
        type: "commandExecution"
      },
      threadId: "thread-new",
      turnId: "turn-1"
    })
    const approval = client.serverRequest("item/commandExecution/requestApproval", {
      itemId: "cmd-1",
      threadId: "thread-new",
      turnId: "turn-1"
    })
    await Promise.resolve()
    const asked = events.at(-1)?.payload as Record<string, unknown>
    expect(asked).toMatchObject({
      message: "rm -rf build",
      sessionUpdate: "question"
    })
    expect(asked.questions).toEqual([
      {
        allowsOther: false,
        header: "Command",
        id: "approval",
        options: [{ label: "Allow" }, { label: "Allow for session" }, { label: "Deny" }],
        question: "Allow this command to run?"
      }
    ])
    await run(
      created!.handle.answerQuestion!(asked.questionId as string, {
        answers: { approval: { answers: ["Allow for session"] } },
        outcome: "answered"
      })
    )
    await expect(approval).resolves.toEqual({ decision: "acceptForSession" })

    // Deny and dismissal map onto decline/cancel.
    const denied = client.serverRequest("item/fileChange/requestApproval", {
      itemId: "edit-1",
      threadId: "thread-new",
      turnId: "turn-1"
    })
    await Promise.resolve()
    const deniedAsk = events.at(-1)?.payload as Record<string, unknown>
    await run(
      created!.handle.answerQuestion!(deniedAsk.questionId as string, {
        answers: { approval: { answers: ["Deny"] } },
        outcome: "answered"
      })
    )
    await expect(denied).resolves.toEqual({ decision: "decline" })

    const dismissed = client.serverRequest("item/permissions/requestApproval", {
      itemId: "perm-1",
      threadId: "thread-new",
      turnId: "turn-1"
    })
    await Promise.resolve()
    const dismissedAsk = events.at(-1)?.payload as Record<string, unknown>
    await run(
      created!.handle.answerQuestion!(dismissedAsk.questionId as string, { outcome: "cancelled" })
    )
    await expect(dismissed).resolves.toEqual({ decision: "cancel" })
  })

  it("rejects requestUserInput asks that carry no questions", async () => {
    const { client } = await setup()
    await expect(
      client.serverRequest("item/tool/requestUserInput", {
        itemId: "item-q5",
        questions: [],
        threadId: "thread-new",
        turnId: "turn-1"
      })
    ).rejects.toThrow("no questions")
  })

  it("renders completed plan items as plan documents, not tool calls", async () => {
    const { client, events } = await setup()
    client.emit("item/started", {
      item: { id: "plan-1", text: "", type: "plan" },
      threadId: "thread-new",
      turnId: "turn-1"
    })
    client.emit("item/completed", {
      item: { id: "plan-1", text: "# Proposed Plan\n\n- step one", type: "plan" },
      threadId: "thread-new",
      turnId: "turn-1"
    })
    // Empty plan text emits nothing.
    client.emit("item/completed", {
      item: { id: "plan-2", text: "", type: "plan" },
      threadId: "thread-new",
      turnId: "turn-1"
    })
    const payloads = events.map((event) => event.payload as Record<string, unknown>)
    expect(payloads.filter((payload) => payload.sessionUpdate === "plan_document")).toEqual([
      { markdown: "# Proposed Plan\n\n- step one", sessionUpdate: "plan_document" }
    ])
    expect(
      payloads.filter(
        (payload) =>
          (payload.sessionUpdate === "tool_call" || payload.sessionUpdate === "tool_call_update") &&
          payload.toolCallId === "plan-1"
      )
    ).toEqual([])
  })

  it("advertises goal support and sets goals with double-option budget semantics", async () => {
    const { client, created, events } = await setup()
    expect(created?.metadata.supportsGoals).toBe(true)

    // Omitted budget key stays omitted on the wire (keep semantics).
    const goal = await run(created!.handle.setGoal!({ objective: "ship goal mode" }))
    let request = client.requests.findLast((entry) => entry.method === "thread/goal/set")
    expect(request?.params).toEqual({ objective: "ship goal mode", threadId: "thread-new" })
    expect(goal.objective).toBe("ship goal mode")
    expect(goal.status).toBe("active")
    expect(goal.createdAt).toBe(new Date(1_700_000_000 * 1000).toISOString())
    expect(events.at(-1)?.payload).toEqual({ goal })

    // A number sets the budget; pause is just a status update.
    await run(created!.handle.setGoal!({ status: "paused", tokenBudget: 50_000 }))
    request = client.requests.findLast((entry) => entry.method === "thread/goal/set")
    expect(request?.params).toEqual({
      status: "paused",
      threadId: "thread-new",
      tokenBudget: 50_000
    })

    // Explicit null clears the budget (double-option), keeping the objective.
    const cleared = await run(created!.handle.setGoal!({ tokenBudget: null }))
    request = client.requests.findLast((entry) => entry.method === "thread/goal/set")
    expect(request?.params).toEqual({ threadId: "thread-new", tokenBudget: null })
    expect(cleared.objective).toBe("ship goal mode")
    expect(cleared.tokenBudget).toBeNull()
  })

  it("clears goals and forwards agent-side cleared notifications", async () => {
    const { client, created, events } = await setup()
    await run(created!.handle.setGoal!({ objective: "tidy up" }))
    await run(created!.handle.clearGoal!)
    expect(client.requests.at(-1)).toMatchObject({
      method: "thread/goal/clear",
      params: { threadId: "thread-new" }
    })
    expect(events.at(-1)?.payload).toEqual({ goalCleared: true })

    client.emit("thread/goal/cleared", { threadId: "thread-new" })
    await Promise.resolve()
    expect(events.at(-1)?.payload).toEqual({ goalCleared: true })
  })

  it("emits out-of-band goal snapshots immediately and throttles accounting ticks", async () => {
    const { client, events } = await setup()
    const snapshot = (overrides: Record<string, unknown>) => ({
      createdAt: 1_700_000_000,
      objective: "long haul",
      status: "active",
      threadId: "thread-new",
      timeUsedSeconds: 1,
      tokenBudget: 10_000,
      tokensUsed: 100,
      updatedAt: 1_700_000_001,
      ...overrides
    })

    // Out-of-band snapshot (turnId null — e.g. resume) always emits.
    client.emit("thread/goal/updated", { goal: snapshot({}), threadId: "thread-new", turnId: null })
    expect(events.at(-1)?.payload).toMatchObject({ goal: { objective: "long haul" } })
    const countAfterSnapshot = events.length

    // Accounting-only tick inside a turn within the rate window is held back.
    client.emit("thread/goal/updated", {
      goal: snapshot({ tokensUsed: 200 }),
      threadId: "thread-new",
      turnId: "turn-1"
    })
    expect(events.length).toBe(countAfterSnapshot)

    // A material change (status flip) bypasses the throttle.
    client.emit("thread/goal/updated", {
      goal: snapshot({ status: "budgetLimited", tokensUsed: 10_000 }),
      threadId: "thread-new",
      turnId: "turn-1"
    })
    expect(events.at(-1)?.payload).toMatchObject({
      goal: { status: "budgetLimited", tokensUsed: 10_000 }
    })

    // Malformed goals are skipped, not thrown.
    client.emit("thread/goal/updated", {
      goal: snapshot({ status: "later" }),
      threadId: "thread-new",
      turnId: "turn-1"
    })
    client.emit("thread/goal/updated", { goal: "nope", threadId: "thread-new", turnId: "turn-1" })
    expect(events.at(-1)?.payload).toMatchObject({ goal: { status: "budgetLimited" } })
  })

  it("flushes held accounting snapshots before the turn-ended event", async () => {
    const { client, created, events } = await setup()
    const promptPromise = run(created!.handle.prompt("work"))
    await Promise.resolve()
    client.emit("turn/started", { threadId: "thread-new", turn: { id: "turn-1" } })
    const goal = {
      createdAt: 1_700_000_000,
      objective: "long haul",
      status: "active",
      threadId: "thread-new",
      timeUsedSeconds: 1,
      tokenBudget: null,
      tokensUsed: 50,
      updatedAt: 1_700_000_001
    }
    // First in-turn update emits (it materially differs from "no goal")…
    client.emit("thread/goal/updated", { goal, threadId: "thread-new", turnId: "turn-1" })
    // …then a same-shape accounting tick is held by the rate limit.
    client.emit("thread/goal/updated", {
      goal: { ...goal, tokensUsed: 999 },
      threadId: "thread-new",
      turnId: "turn-1"
    })
    const heldCount = events.length
    client.emit("turn/completed", {
      threadId: "thread-new",
      turn: { id: "turn-1", status: "completed" }
    })
    await promptPromise
    expect(events.length).toBeGreaterThan(heldCount)
    const goalFlush = events.at(-2)
    const turnEnded = events.at(-1)
    expect(goalFlush?.payload).toMatchObject({ goal: { tokensUsed: 999 } })
    expect(turnEnded?.payload).toMatchObject({ turnState: "ended" })
  })

  it("labels goal auto-continuation turns as agent-initiated", async () => {
    const { client, events } = await setup({ resume: "thread-resumed" })
    // Resume flow: codex replays a goal snapshot then may start a turn itself.
    client.emit("thread/goal/updated", {
      goal: {
        createdAt: 1_700_000_000,
        objective: "keep going",
        status: "active",
        threadId: "thread-resumed",
        timeUsedSeconds: 0,
        tokenBudget: null,
        tokensUsed: 0,
        updatedAt: 1_700_000_000
      },
      threadId: "thread-resumed",
      turnId: null
    })
    client.emit("turn/started", { threadId: "thread-resumed", turn: { id: "turn-goal" } })
    const started = events.at(-1)
    expect(started?.payload).toMatchObject({
      initiatedBy: "agent",
      turnId: "turn-goal",
      turnState: "started"
    })
  })
})
