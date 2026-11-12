import { mkdtempSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"

import { describe, expect, it } from "vitest"

import { makeEventFanout } from "../server.js"
import { makeServices, run, tempDirs } from "../test-support.js"
import { sessionEventSink } from "./session-events.js"

const wakeEvent = [
  '<codevisor-event type="harness.task_finished" taskId="bg-1" status="completed">',
  "tests passed",
  "</codevisor-event>"
].join("\n")

const harnessSink = async () => {
  const { services } = await makeServices("session-event-sink")
  const folder = mkdtempSync(join(tmpdir(), "codevisor-event-sink-"))
  tempDirs.push(folder)
  const project = await run(services.db.createProject({ folderPath: folder }))
  const session = await run(
    services.db.createSession({ projectId: project.id, harnessId: "claude-code" })
  )
  const sink = sessionEventSink(services, await run(makeEventFanout), "event-sink", session.id)
  const emit = (payload: Record<string, unknown>) =>
    sink({ kind: "session.output", subjectId: session.id, payload })
  const userItems = async () =>
    (await run(services.db.getTranscriptPage(session.id, undefined, 20))).items
      .filter((item) => item.role === "user")
      .map((item) => ({ text: item.text, origin: item.origin }))
  return { emit, userItems }
}

describe("sessionEventSink", () => {
  it("records an event prompt a harness reports, but not a typed prompt it echoes", async () => {
    const { emit, userItems } = await harnessSink()

    await emit({ role: "user", messageId: "typed-1", text: "Run the tests" })
    await emit({
      role: "user",
      messageId: "wake-1",
      origin: "event",
      startsTurn: true,
      text: wakeEvent
    })

    expect(await userItems()).toEqual([{ text: wakeEvent, origin: "event" }])
  })
})
