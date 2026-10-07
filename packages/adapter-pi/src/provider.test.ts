import { mkdtemp, rm } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"

import { describe, expect, it, onTestFinished } from "vitest"

import { makePiProvider } from "./provider.js"
import { piPrompt } from "./session.js"
import { claude, codex, definition, environment, payloads, run, setup } from "./test-support.js"

const settled = [
  { type: "agent_start" },
  { type: "message_start", message: { role: "assistant", timestamp: 1 } },
  {
    type: "message_update",
    assistantMessageEvent: { type: "text_delta", contentIndex: 0, delta: "Hello" }
  },
  { type: "message_end", message: { role: "assistant", stopReason: "stop", usage: {} } },
  { type: "agent_end" },
  { type: "agent_settled" }
]

const turnStates = (events: ReadonlyArray<{ payload: unknown }>) =>
  payloads(events as never).flatMap((payload) =>
    payload.turnState === undefined
      ? []
      : [
          [
            payload.turnState,
            payload.initiatedBy,
            ...(payload.stopReason === undefined ? [] : [payload.stopReason]),
            ...(payload.stopDetail === undefined ? [] : [payload.stopDetail])
          ]
        ]
  )

describe("Pi provider", () => {
  it("starts Pi in RPC mode with the account's environment and the gateway", async () => {
    const { provider, spawned, client } = setup()
    const created = await run(
      provider.createSession(
        definition,
        "/project",
        async () => undefined,
        {
          id: "pi",
          profileKind: "default",
          env: { PI_CODING_AGENT_DIR: "/profile" },
          unsetEnv: ["PATH"]
        },
        { name: "codevisor", url: "http://127.0.0.1:9/mcp", bearerToken: "token" }
      )
    )
    expect(spawned).toEqual([
      {
        command: "/bin/pi",
        args: ["-e", "/tmp/codevisor-gateway.ts"],
        cwd: "/project",
        env: {
          PI_CODING_AGENT_DIR: "/profile",
          CODEVISOR_MCP_GATEWAY_NAME: "codevisor",
          CODEVISOR_MCP_GATEWAY_URL: "http://127.0.0.1:9/mcp",
          CODEVISOR_MCP_GATEWAY_TOKEN: "token"
        }
      }
    ])
    expect(created.metadata).toEqual({
      sessionId: "pi-1",
      configOptions: [
        expect.objectContaining({ id: "model", currentValue: "openai-codex/gpt-6" }),
        expect.objectContaining({ id: "thought_level", currentValue: "medium" })
      ]
    })
    expect(client.commands.map((command) => command.type)).toEqual([
      "get_state",
      "get_available_models",
      "get_available_thinking_levels"
    ])
    await run(created.handle.close)
    expect(client.closed).toBe(true)
  })

  it("reopens a chat's own Pi session, and runs without a gateway", async () => {
    const { provider, spawned } = setup()
    const loaded = await run(
      provider.loadSession(definition, "pi-1", "/project", async () => undefined)
    )
    expect(loaded.sessionId).toBe("pi-1")
    expect(spawned[0]).toMatchObject({ args: ["--session", "pi-1"], env: { PATH: "/bin" } })
  })

  it("runs a turn from the prompt until Pi settles", async () => {
    const { provider, client, events, emit } = setup()
    const { handle } = await run(provider.createSession(definition, "/p", emit))
    const result = run(handle.prompt({ text: "hi" }))
    await Promise.resolve()
    client.emit(...settled)
    await expect(result).resolves.toEqual({ stopReason: "end_turn" })
    expect(client.commands.at(-1)).toEqual({ type: "prompt", fields: { message: "hi" } })
    expect(turnStates(events)).toEqual([
      ["started", "user"],
      ["ended", "user", "end_turn"]
    ])
    expect(payloads(events)).toContainEqual(
      expect.objectContaining({ sessionUpdate: "agent_message_chunk", messageId: "pi-1-1:0" })
    )
    expect(events.every((event) => event.subjectId === "pi-1")).toBe(true)
  })

  it("reports a provider error as the turn's reason, and a cancel as cancelled", async () => {
    const { provider, client, events, emit } = setup()
    const { handle } = await run(provider.createSession(definition, "/p", emit))
    const failing = [
      { type: "message_start", message: { role: "assistant" } },
      {
        type: "message_end",
        message: { role: "assistant", stopReason: "error", errorMessage: "429 rate limited" }
      },
      { type: "agent_settled" }
    ]
    const first = run(handle.prompt("one"))
    await Promise.resolve()
    client.emit(...failing)
    await first
    const second = run(handle.prompt("two"))
    await Promise.resolve()
    client.emit(
      failing[0]!,
      { ...failing[1]!, message: { role: "assistant", stopReason: "error" } },
      failing[2]!
    )
    await second
    const third = run(handle.prompt("three"))
    await Promise.resolve()
    expect(await run(handle.cancel)).toEqual({ runtimeState: "reusable" })
    client.emit(
      failing[0]!,
      {
        ...failing[1]!,
        message: {
          role: "assistant",
          stopReason: "error",
          errorMessage: "This operation was aborted"
        }
      },
      failing[2]!
    )
    await expect(third).resolves.toEqual({ stopReason: "cancelled" })
    expect(turnStates(events).filter(([state]) => state === "ended")).toEqual([
      ["ended", "user", "end_turn", "429 rate limited"],
      ["ended", "user", "end_turn", "Pi stopped with an error."],
      ["ended", "user", "cancelled"]
    ])
    expect(client.commands.some((command) => command.type === "abort")).toBe(true)
    // Cancelling with nothing running just asks Pi to stop.
    await run(handle.cancel)
  })

  it("ends a turn Pi handles without running, or refuses", async () => {
    const { provider, client, events, emit } = setup()
    const { handle } = await run(provider.createSession(definition, "/p", emit))
    client.replies.prompt = { disposition: "handled" }
    await expect(run(handle.prompt("/reload"))).resolves.toEqual({ stopReason: "end_turn" })
    client.replies.prompt = new Error("No model selected")
    await expect(run(handle.prompt("hi"))).resolves.toEqual({ stopReason: "end_turn" })
    client.replies.prompt = "unexpected"
    const queued = run(handle.prompt("hi"))
    await Promise.resolve()
    client.emit({ type: "agent_settled" })
    await queued
    expect(turnStates(events).filter(([state]) => state === "ended")).toEqual([
      ["ended", "user", "end_turn"],
      ["ended", "user", "end_turn", "No model selected"],
      ["ended", "user", "end_turn"]
    ])
    // A settle with no turn running changes nothing.
    client.emit({ type: "agent_settled" })
    expect(turnStates(events)).toHaveLength(6)
  })

  it("follows work Pi starts on its own", async () => {
    const { provider, client, events, emit } = setup()
    await run(provider.createSession(definition, "/p", emit))
    client.emit(...settled)
    expect(turnStates(events)).toEqual([
      ["started", "agent"],
      ["ended", "agent", "end_turn"]
    ])
  })

  it("asks Pi's dialogs as questions, and cancels the open ones when the turn ends", async () => {
    const { provider, client, events, emit } = setup()
    const { handle } = await run(provider.createSession(definition, "/p", emit))
    const result = run(handle.prompt("go"))
    await Promise.resolve()
    client.emit(
      {
        type: "extension_ui_request",
        id: "d1",
        method: "confirm",
        title: "Proceed?",
        message: "Sure?"
      },
      { type: "extension_ui_request", id: "d2", method: "input", title: "Name?" },
      { type: "extension_ui_request", id: "d3", method: "notify", message: "fyi" },
      { type: "extension_ui_request", method: "confirm", title: "No id" }
    )
    const asked = payloads(events).filter((payload) => payload.sessionUpdate === "question")
    expect(asked).toHaveLength(2)
    expect(asked[0]).toMatchObject({ message: "Sure?", questions: [{ question: "Proceed?" }] })
    await run(
      handle.answerQuestion!(String(asked[0]!.questionId), {
        outcome: "answered",
        answers: { answer: { answers: ["Yes"] } }
      })
    )
    expect(client.responses).toEqual([{ id: "d1", confirmed: true }])
    await expect(run(handle.answerQuestion!("missing", { outcome: "cancelled" }))).rejects.toThrow(
      "No pending question"
    )
    client.emit({ type: "agent_settled" })
    await result
    expect(client.responses).toEqual([
      { id: "d1", confirmed: true },
      { id: "d2", cancelled: true }
    ])
    expect(
      payloads(events)
        .filter((payload) => payload.sessionUpdate === "question_resolved")
        .map((payload) => payload.outcome)
    ).toEqual(["answered", "cancelled"])
  })

  it("switches model and thinking level, and follows Pi's own changes", async () => {
    const { provider, client, events, emit } = setup()
    client.replies.get_available_models = { models: [codex, claude] }
    const { handle } = await run(provider.createSession(definition, "/p", emit))
    client.replies.get_available_thinking_levels = { levels: ["off", "high"] }
    client.replies.get_state = { sessionId: "pi-1", thinkingLevel: "high" }
    const afterModel = await run(handle.setConfigOption("model", "anthropic/sonnet"))
    expect(client.commands.find((command) => command.type === "set_model")?.fields).toEqual({
      provider: "anthropic",
      modelId: "sonnet"
    })
    expect(afterModel.map((option) => option.currentValue)).toEqual(["anthropic/sonnet", "high"])
    // Pi answering set_model without a model keeps the previous one.
    client.replies.set_model = null
    client.replies.get_state = { sessionId: "pi-1" }
    expect(
      (await run(handle.setConfigOption("model", "openai-codex/gpt-6")))[0]?.currentValue
    ).toBe("anthropic/sonnet")
    expect((await run(handle.setConfigOption("thought_level", "off")))[1]?.currentValue).toBe("off")
    await expect(run(handle.setConfigOption("model", "nonsense"))).rejects.toThrow("Unknown model")
    await expect(run(handle.setConfigOption("speed", "fast"))).rejects.toThrow(
      "no setting named speed"
    )
    await expect(run(handle.setMode("plan"))).rejects.toThrow("no mode named plan")
    client.emit(
      { type: "thinking_level_changed", level: "high" },
      { type: "thinking_level_changed" }
    )
    const updates = payloads(events).filter((payload) => payload.configOptions !== undefined)
    expect(updates).toHaveLength(1)
    expect((updates[0]!.configOptions as Array<{ currentValue: string }>)[1]?.currentValue).toBe(
      "high"
    )
  })

  it("reports Pi exiting, ending the running turn", async () => {
    const { provider, client, events, emit } = setup()
    const { handle } = await run(provider.createSession(definition, "/p", emit))
    const result = run(handle.prompt("hi"))
    await Promise.resolve()
    client.crash(new Error("pi exited: out of memory"))
    await expect(result).resolves.toEqual({ stopReason: "end_turn" })
    expect(events.some((event) => event.kind === "session.error")).toBe(true)
    expect(turnStates(events).at(-1)).toEqual([
      "ended",
      "user",
      "end_turn",
      "pi exited: out of memory"
    ])
  })

  it("asks for a newer Pi when its RPC mode lacks what chats need", async () => {
    const { provider, client } = setup()
    client.replies.get_available_thinking_levels = new Error("Unknown command")
    client.replies.get_state = { sessionId: 7, model: { id: "x" } }
    client.replies.get_available_models = { models: [{ id: "bad" }, "junk", codex] }
    await expect(
      run(provider.createSession(definition, "/p", async () => undefined))
    ).rejects.toThrow("Update Pi to 0.81.0 or newer")
    expect(client.closed).toBe(true)
    client.replies.get_available_thinking_levels = { levels: "none" }
    client.replies.get_available_models = {}
    const { metadata } = await run(provider.createSession(definition, "/p", async () => undefined))
    expect(metadata).toEqual({ sessionId: "7", configOptions: [] })
  })

  it("is ready only where Pi is installed, and lists the account's sessions", async () => {
    const { provider } = setup({
      scanAgentSessions: async (agentDir) => [{ sessionId: String(agentDir), cwd: "/" }]
    })
    expect(provider.readiness(definition)).toEqual({ state: "ready" })
    expect(
      provider.readiness({ ...definition, detectBinaries: ["missing"], fallbackPaths: ["/opt/pi"] })
    ).toEqual({
      detail: "CLI not found on PATH",
      state: "unavailable"
    })
    await expect(
      run(
        provider.createSession(
          { ...definition, detectBinaries: ["missing"] },
          "/p",
          async () => undefined
        )
      )
    ).rejects.toThrow("pi not found on PATH")
    expect(
      await provider.listAgentSessions!(definition, {
        id: "pi",
        profileKind: "default",
        env: { PI_CODING_AGENT_DIR: "/profile" }
      })
    ).toEqual([{ sessionId: "/profile", cwd: "/" }])
    expect(await provider.listAgentSessions!(definition)).toEqual([
      { sessionId: "undefined", cwd: "/" }
    ])
    // By default sessions are read from the account's agent dir.
    const agentDir = await mkdtemp(join(tmpdir(), "codevisor-pi-sessions-"))
    onTestFinished(() => rm(agentDir, { recursive: true, force: true }))
    expect(
      await makePiProvider(environment).listAgentSessions!(definition, {
        id: "pi",
        profileKind: "default",
        env: { PI_CODING_AGENT_DIR: agentDir }
      })
    ).toEqual([])
  })

  it("is signed in when Pi has a model to use", async () => {
    const { provider, client, spawned } = setup()
    expect(
      await run(
        provider.probeAuth!(definition, {
          id: "pi",
          profileKind: "default",
          env: { PI_CODING_AGENT_DIR: "/p" }
        })
      )
    ).toEqual({ state: "authenticated", methods: [], canLogout: false })
    expect(spawned[0]).toMatchObject({ args: ["--no-session"], env: { PI_CODING_AGENT_DIR: "/p" } })
    expect(client.closed).toBe(true)
    client.replies.get_available_models = { models: [] }
    expect(await run(provider.probeAuth!(definition))).toMatchObject({
      state: "unauthenticated",
      detail: "Sign in to a provider to use Pi."
    })
    client.replies.get_available_models = null
    expect((await run(provider.probeAuth!(definition))).state).toBe("unauthenticated")
    client.replies.get_available_models = new Error("pi exited")
    expect(await run(provider.probeAuth!(definition))).toMatchObject({
      state: "error",
      detail: "pi exited"
    })
    client.replies.get_available_models = new Error("")
    expect((await run(provider.probeAuth!(definition))).detail).toBe("Couldn't check Pi's sign-in.")
    await expect(
      run(provider.probeAuth!({ ...definition, detectBinaries: ["missing"] }))
    ).rejects.toThrow("pi not found on PATH")
  })

  it("sends images inline and other attachments as path notes", () => {
    const image = {
      name: "a.png",
      mimeType: "image/png",
      kind: "image" as const,
      sizeBytes: 3,
      path: "/tmp/a.png",
      inline: { mimeType: "image/png", data: Buffer.from("png") }
    }
    const { inline: _inline, ...withoutInline } = image
    const big = { ...withoutInline, name: "big.png", path: "/tmp/big.png", inlineOmitted: true }
    const file = {
      name: "b.pdf",
      mimeType: "application/pdf",
      kind: "file" as const,
      sizeBytes: 9,
      path: "/tmp/b.pdf"
    }
    const prompt = piPrompt({ text: "Look", attachments: [image, big, file] })
    expect(prompt.images).toEqual([
      { type: "image", data: Buffer.from("png").toString("base64"), mimeType: "image/png" }
    ])
    expect(prompt.message).toContain("/tmp/big.png")
    expect(prompt.message).toContain("/tmp/b.pdf")
    expect(piPrompt({ text: "Plain" })).toEqual({ message: "Plain" })
  })
})
