import { describe, expect, it } from "vitest"

import { MuseRequestError } from "./client.js"
import { send, SESSION, startChat as start } from "./test-support.js"

describe("Muse chat steering", () => {
  it("steers the running turn until its foreground work completes", async () => {
    const { client, chat } = await start()
    await expect(chat.steer("too early")).resolves.toBe(false)
    const { finished, turnId } = await send(chat, client, "long task")
    await expect(chat.steer("also check the tests")).resolves.toBe(true)
    expect(client.sent("turn/steer")).toEqual([
      {
        commandId: expect.stringMatching(/^[0-9a-f]{8}-[0-9a-f]{4}-7/),
        sessionId: SESSION,
        expectedTurnId: turnId,
        input: [{ type: "text", text: "also check the tests" }]
      }
    ])
    client.emit("turn/foregroundCompleted", { turnId: "someone-else" })
    await expect(chat.steer("still running")).resolves.toBe(true)
    client.emit("turn/foregroundCompleted", { turnId })
    await expect(chat.steer("too late")).resolves.toBe(false)
    expect(client.sent("turn/steer")).toHaveLength(2)
    client.emit("turn/completed", { turnId, terminal: "completed" })
    await expect(finished).resolves.toEqual({ stopReason: "end_turn" })
    await expect(chat.steer("after")).resolves.toBe(false)
    expect(client.sent("turn/steer")).toHaveLength(2)
  })

  it("declines a steer Muse rejects, files under another turn, or that follows a cancel", async () => {
    const { client, chat } = await start()
    await send(chat, client, "long task")
    client.replies["turn/steer"] = new MuseRequestError(
      "already_terminal",
      -32030,
      "commandRejected"
    )
    await expect(chat.steer("rejected")).resolves.toBe(false)
    client.replies["turn/steer"] = (params: Record<string, unknown>) => ({
      commandId: params.commandId,
      status: "accepted",
      turnId: params.commandId
    })
    await expect(chat.steer("misfiled")).resolves.toBe(false)
    client.replies["turn/steer"] = new Error("socket closed")
    await expect(chat.steer("broken")).rejects.toThrow("socket closed")
    await chat.cancel()
    await expect(chat.steer("cancelled")).resolves.toBe(false)
    expect(client.sent("turn/steer")).toHaveLength(3)
  })
})
