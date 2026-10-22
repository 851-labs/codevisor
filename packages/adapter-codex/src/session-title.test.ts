import { describe, expect, it } from "vitest"

import { payloadField, setup } from "./test-support.js"

describe("Codex session titles", () => {
  it("titles the chat from Codex thread renames and rereads a blank name", async () => {
    const { client, events, nextEvent } = await setup()
    client.emit("thread/name/updated", { threadId: "thread-new", threadName: "  Fix the build  " })
    client.threadName = "Stored name"
    const reread = nextEvent((event) => payloadField(event, "title") === "Stored name")
    client.emit("thread/name/updated", { threadId: "thread-new", threadName: "   " })
    await reread
    expect(
      events.filter((event) => payloadField(event, "sessionUpdate") === "session_info_update")
    ).toEqual([
      {
        kind: "session.updated",
        payload: { sessionUpdate: "session_info_update", title: "Fix the build" },
        subjectId: "thread-new"
      },
      {
        kind: "session.updated",
        payload: { sessionUpdate: "session_info_update", title: "Stored name" },
        subjectId: "thread-new"
      }
    ])
  })
})
