import { describe, expect, it, onTestFinished } from "vitest"

import { makeDatabase } from "./index.js"
import { parseAttribution } from "./prompt-attribution.js"
import { run } from "./test-support.js"

const viaZillow = { kind: "app", viewId: "view-1", plugin: "Zillow" } as const

const fixture = async () => {
  const db = await run(makeDatabase({ filename: ":memory:", serverId: "local" }))
  onTestFinished(() => run(db.close))
  const project = await run(db.createProject({ folderPath: "/tmp/prompt-attribution" }))
  const session = await run(db.createSession({ projectId: project.id, harnessId: "codex" }))
  return { db, session }
}

describe("prompt attribution", () => {
  it("keeps who sent a queued prompt", async () => {
    const { db, session } = await fixture()

    const queued = await run(
      db.createPromptQueueItem(session.id, "Tour it", [], undefined, undefined, "user", viaZillow)
    )
    await run(db.createPromptQueueItem(session.id, "Typed"))

    expect(queued.attribution).toEqual(viaZillow)
    expect((await run(db.listPromptQueue(session.id))).map((item) => item.attribution)).toEqual([
      viaZillow,
      undefined
    ])
    expect((await run(db.claimPromptQueueItem(session.id)))?.attribution).toEqual(viaZillow)
  })

  it("shows it on the user's transcript item and ignores malformed ones", async () => {
    const { db, session } = await fixture()

    await run(
      db.appendEvent("session.output", session.id, {
        role: "user",
        messageId: "m-1",
        text: "Tour it",
        attribution: viaZillow
      })
    )
    await run(
      db.appendEvent("session.output", session.id, {
        role: "user",
        messageId: "m-2",
        text: "Typed",
        attribution: { kind: "bot" }
      })
    )

    const transcript = await run(db.getTranscriptPage(session.id, undefined, 32))
    expect(
      transcript.items.filter((item) => item.role === "user").map((item) => item.attribution)
    ).toEqual([viaZillow, undefined])
  })

  it("reads nothing from missing or corrupt columns", () => {
    expect(parseAttribution(null)).toBeUndefined()
    expect(parseAttribution(undefined)).toBeUndefined()
    expect(parseAttribution("{")).toBeUndefined()
    expect(parseAttribution(JSON.stringify(viaZillow))).toEqual(viaZillow)
  })
})
