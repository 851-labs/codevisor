import { WebSocket } from "ws"
import { describe, expect, it } from "vitest"
import { jsonRequest, start, waitFor } from "../test-support.js"

describe("terminal routes", () => {
  it("kills a session's terminal over the delete route", async () => {
    const { server, spawner } = await start()

    // No live terminal for the session yet.
    const missing = await jsonRequest(server, "/v1/terminals/session/no-such-session", {
      method: "DELETE"
    })
    expect(missing.status).toBe(404)
    expect(missing.body).toEqual({ closed: false })

    await jsonRequest(server, "/v1/terminals", {
      body: JSON.stringify({
        sessionId: "session-kill",
        cwd: "/tmp/codevisor",
        cols: 80,
        rows: 24
      }),
      method: "POST"
    })
    const closed = await jsonRequest(server, "/v1/terminals/session/session-kill", {
      method: "DELETE"
    })
    expect(closed.status).toBe(200)
    expect(closed.body).toEqual({ closed: true })
    expect(spawner.processes[0]?.killCount).toBe(1)
  })

  it("bridges terminal create and websocket traffic", async () => {
    const { server, spawner } = await start()
    const terminalResponse = await jsonRequest(server, "/v1/terminals", {
      body: JSON.stringify({ sessionId: "session-1", cwd: "/tmp/codevisor", cols: 80, rows: 24 }),
      method: "POST"
    })
    expect((await jsonRequest(server, "/v1/terminals", { method: "POST" })).status).toBe(400)
    const terminal = terminalResponse.body as {
      readonly terminalId: string
      readonly websocketPath: string
    }
    const webSocket = new WebSocket(
      `${server.url.replace("http:", "ws:")}${terminal.websocketPath}?lastOutputSeq=0`
    )
    const messages: Array<unknown> = []

    await new Promise<void>((resolve, reject) => {
      webSocket.once("open", resolve)
      webSocket.once("error", reject)
    })
    webSocket.on("message", (data) => messages.push(JSON.parse(data.toString()) as unknown))
    await new Promise((resolve) => setTimeout(resolve, 20))
    webSocket.send("{")
    await waitFor(() => messages.length === 1)
    webSocket.send(
      JSON.stringify({ type: "input", clientId: "client-a", clientSeq: 1, data: "pwd\n" })
    )
    webSocket.send(
      JSON.stringify({ type: "resize", clientId: "client-a", clientSeq: 2, cols: 120, rows: 30 })
    )
    await waitFor(
      () => spawner.processes[0]?.writes.length === 1 && spawner.processes[0]?.resizes.length === 1,
      () =>
        JSON.stringify({
          processCount: spawner.processes.length,
          resizes: spawner.processes[0]?.resizes ?? [],
          writes: spawner.processes[0]?.writes ?? []
        })
    )
    spawner.handlers[0]?.onOutput("terminal-output")
    spawner.handlers[0]?.onExit(0)

    await waitFor(
      () => messages.length === 3,
      () =>
        JSON.stringify({
          messages,
          processCount: spawner.processes.length,
          readyState: webSocket.readyState,
          writes: spawner.processes[0]?.writes ?? []
        })
    )
    webSocket.send(
      JSON.stringify({ type: "input", clientId: "client-a", clientSeq: 3, data: "after-exit" })
    )
    await waitFor(() => messages.length === 4)
    webSocket.close()

    expect(spawner.processes[0]?.writes).toEqual(["pwd\n"])
    expect(spawner.processes[0]?.resizes).toEqual([[120, 30]])
    expect(messages).toEqual([
      expect.objectContaining({ type: "error" }),
      { type: "output", seq: 1, data: "terminal-output" },
      { type: "exit", seq: 2, exitCode: 0 },
      expect.objectContaining({ type: "error" })
    ])

    const replaySocket = new WebSocket(
      `${server.url.replace("http:", "ws:")}${terminal.websocketPath}?lastOutputSeq=not-a-number`
    )
    const replayMessages: Array<unknown> = []
    replaySocket.on("message", (data) =>
      replayMessages.push(JSON.parse(data.toString()) as unknown)
    )
    await new Promise<void>((resolve, reject) => {
      replaySocket.once("open", resolve)
      replaySocket.once("error", reject)
    })
    await waitFor(() => replayMessages.length === 2)
    expect(replayMessages).toEqual([
      { type: "output", seq: 1, data: "terminal-output" },
      { type: "exit", seq: 2, exitCode: 0 }
    ])
    replaySocket.close()

    const cursorReplaySocket = new WebSocket(
      `${server.url.replace("http:", "ws:")}${terminal.websocketPath}?lastOutputSeq=1`
    )
    const cursorReplayMessages: Array<unknown> = []
    cursorReplaySocket.on("message", (data) =>
      cursorReplayMessages.push(JSON.parse(data.toString()) as unknown)
    )
    await new Promise<void>((resolve, reject) => {
      cursorReplaySocket.once("open", resolve)
      cursorReplaySocket.once("error", reject)
    })
    await waitFor(() => cursorReplayMessages.length === 1)
    expect(cursorReplayMessages).toEqual([{ type: "exit", seq: 2, exitCode: 0 }])
    cursorReplaySocket.close()

    const missingSocket = new WebSocket(
      `${server.url.replace("http:", "ws:")}/v1/terminals/missing/socket`
    )
    const missingMessages: Array<unknown> = []
    missingSocket.on("message", (data) =>
      missingMessages.push(JSON.parse(data.toString()) as unknown)
    )
    await new Promise<void>((resolve, reject) => {
      missingSocket.once("open", resolve)
      missingSocket.once("error", reject)
    })
    await waitFor(() => missingMessages.length === 1)
    expect(missingMessages[0]).toMatchObject({ type: "error" })
    missingSocket.close()

    const badPathSocket = new WebSocket(`${server.url.replace("http:", "ws:")}/v1/not-a-terminal`)
    await new Promise<void>((resolve) => {
      badPathSocket.once("close", resolve)
      badPathSocket.once("error", () => resolve())
    })
  })
})
