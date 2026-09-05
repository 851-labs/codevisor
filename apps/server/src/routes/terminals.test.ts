import { WebSocket } from "ws"
import { describe, expect, it, onTestFinished, vi } from "vitest"
import { jsonRequest, start } from "../test-support.js"

const recordMessages = (socket: WebSocket) => {
  const messages: unknown[] = []
  const waiters = new Map<number, () => void>()
  socket.on("message", (data) => {
    messages.push(JSON.parse(data.toString()))
    waiters.get(messages.length)?.()
    waiters.delete(messages.length)
  })
  onTestFinished(() => socket.terminate())
  return {
    messages,
    received: (count: number) =>
      messages.length >= count
        ? Promise.resolve()
        : new Promise<void>((resolve) => waiters.set(count, resolve))
  }
}

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
    const { messages, received } = recordMessages(webSocket)

    await new Promise<void>((resolve, reject) => {
      webSocket.once("open", resolve)
      webSocket.once("error", reject)
    })
    webSocket.send("{")
    await received(1)
    const written = Promise.withResolvers<void>()
    const resized = Promise.withResolvers<void>()
    const process = spawner.processes[0]!
    const write = process.write.bind(process)
    const resize = process.resize.bind(process)
    vi.spyOn(process, "write").mockImplementation((data) => {
      write(data)
      written.resolve()
    })
    vi.spyOn(process, "resize").mockImplementation((cols, rows) => {
      resize(cols, rows)
      resized.resolve()
    })
    webSocket.send(
      JSON.stringify({ type: "input", clientId: "client-a", clientSeq: 1, data: "pwd\n" })
    )
    webSocket.send(
      JSON.stringify({ type: "resize", clientId: "client-a", clientSeq: 2, cols: 120, rows: 30 })
    )
    await Promise.all([written.promise, resized.promise])
    spawner.handlers[0]?.onOutput("terminal-output")
    spawner.handlers[0]?.onExit(0)

    await received(3)
    webSocket.send(
      JSON.stringify({ type: "input", clientId: "client-a", clientSeq: 3, data: "after-exit" })
    )
    await received(4)
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
    const { messages: replayMessages, received: replayMessagesReceived } =
      recordMessages(replaySocket)
    await new Promise<void>((resolve, reject) => {
      replaySocket.once("open", resolve)
      replaySocket.once("error", reject)
    })
    await replayMessagesReceived(2)
    expect(replayMessages).toEqual([
      { type: "output", seq: 1, data: "terminal-output" },
      { type: "exit", seq: 2, exitCode: 0 }
    ])
    replaySocket.close()

    const cursorReplaySocket = new WebSocket(
      `${server.url.replace("http:", "ws:")}${terminal.websocketPath}?lastOutputSeq=1`
    )
    const { messages: cursorReplayMessages, received: cursorReplayMessagesReceived } =
      recordMessages(cursorReplaySocket)
    await new Promise<void>((resolve, reject) => {
      cursorReplaySocket.once("open", resolve)
      cursorReplaySocket.once("error", reject)
    })
    await cursorReplayMessagesReceived(1)
    expect(cursorReplayMessages).toEqual([{ type: "exit", seq: 2, exitCode: 0 }])
    cursorReplaySocket.close()

    const missingSocket = new WebSocket(
      `${server.url.replace("http:", "ws:")}/v1/terminals/missing/socket`
    )
    const { messages: missingMessages, received: missingMessagesReceived } =
      recordMessages(missingSocket)
    await new Promise<void>((resolve, reject) => {
      missingSocket.once("open", resolve)
      missingSocket.once("error", reject)
    })
    await missingMessagesReceived(1)
    expect(missingMessages[0]).toMatchObject({ type: "error" })
    missingSocket.close()

    const badPathSocket = new WebSocket(`${server.url.replace("http:", "ws:")}/v1/not-a-terminal`)
    await new Promise<void>((resolve) => {
      badPathSocket.once("close", resolve)
      badPathSocket.once("error", () => resolve())
    })
  })
})
